from __future__ import annotations

import json
import re
import socket
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from web3 import HTTPProvider, Web3
from web3.contract import Contract
from web3.exceptions import ContractLogicError

from .role import Role
from .spec import Spec, TokenDef
from .strategy import Action, Strategy


# Anvil deterministic mnemonic accounts (account 0 is the admin/deployer).
ANVIL_ACCOUNTS: list[tuple[str, str]] = [
    ("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"),
    ("0x70997970C51812dc3A010C7d01b50e0d17dc79C8", "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"),
    ("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"),
    ("0x90F79bf6EB2c4f870365E785982E1f101E93b906", "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"),
    ("0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65", "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"),
    ("0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc", "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"),
    ("0x976EA74026E726554dB657fA54763abd0C3a0aa9", "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e"),
    ("0x14dC79964da2C08b23698B3D3cc7Ca32193d9955", "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356"),
    ("0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f", "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97"),
    ("0xa0Ee7A142d267C1f36714E4a8F75612F20a79720", "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dfd3a48fdc"),
]
MAX_UINT256 = (1 << 256) - 1


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _strip_role_suffix(s: str) -> str:
    if s.startswith("@"):
        s = s[1:]
    s = re.sub(r"_if_.*$", "", s)
    return s


@dataclass
class ExecutionResult:
    """Outcome of executing a scenario (one Strategy per role)."""
    asset_deltas: dict[str, dict[str, int]] = field(default_factory=dict)
    final_balances: dict[str, dict[str, int]] = field(default_factory=dict)
    initial_balances: dict[str, dict[str, int]] = field(default_factory=dict)
    action_log: list[str] = field(default_factory=list)
    reverts: list[str] = field(default_factory=list)

    def primary_for(self, role: Role) -> int:
        return self.asset_deltas.get(role.name, {}).get(role.primary_asset, 0)


class Simulator:
    """Anvil-backed Solidity simulator with snapshot/revert per scenario."""

    PSEUDO_ACTIONS = ("wait", "advance_time", "simulate_price_drop", "distribute_rewards")

    def __init__(self, spec_path: str | Path, project_root: str | Path | None = None):
        self.project_root = Path(project_root or Path.cwd()).resolve()
        self.spec_path = Path(spec_path)

        with open(self.spec_path) as f:
            import yaml
            raw = yaml.safe_load(f)
        role_names = [r["name"] for r in raw["roles"]]
        if len(role_names) > len(ANVIL_ACCOUNTS) - 1:
            raise ValueError("more roles than available anvil accounts")
        self.role_addresses: dict[str, str] = {
            name: ANVIL_ACCOUNTS[i + 1][0] for i, name in enumerate(role_names)
        }
        self.admin_address = ANVIL_ACCOUNTS[0][0]

        from .spec import load_spec
        self.spec: Spec = load_spec(self.spec_path, self.role_addresses)

        self._anvil: subprocess.Popen | None = None
        self._port: int | None = None
        self.w3: Web3 | None = None
        self.contract: Contract | None = None
        self._abi: list[dict] | None = None
        self._bytecode: str | None = None
        self._erc20_abi: list[dict] | None = None
        self._erc20_bytecode: str | None = None
        self._token_contracts: dict[str, Contract] = {}
        self._token_addresses: dict[str, str] = {}

    # ------------------------------------------------------------------ build
    def _compile(self) -> None:
        result = subprocess.run(
            ["forge", "build"],
            cwd=self.project_root,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"forge build failed:\n{result.stdout}\n{result.stderr}")
        artifact = (
            self.project_root
            / "out"
            / self.spec.contract_path.name
            / f"{self.spec.contract_name}.json"
        )
        if not artifact.exists():
            raise FileNotFoundError(f"artifact not found: {artifact}")
        data = json.loads(artifact.read_text())
        self._abi = data["abi"]
        self._bytecode = data["bytecode"]["object"]
        if self.spec.tokens:
            erc20_artifact = self.project_root / "out" / "MockERC20.sol" / "MockERC20.json"
            if not erc20_artifact.exists():
                raise FileNotFoundError(
                    f"MockERC20 artifact not found at {erc20_artifact}; "
                    "ensure targets/tier2_realistic/MockERC20.sol exists and forge built it"
                )
            ed = json.loads(erc20_artifact.read_text())
            self._erc20_abi = ed["abi"]
            self._erc20_bytecode = ed["bytecode"]["object"]

    # ------------------------------------------------------------------ anvil
    def _start_anvil(self) -> None:
        self._port = _free_port()
        self._anvil = subprocess.Popen(
            ["anvil", "--port", str(self._port), "--silent"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        url = f"http://127.0.0.1:{self._port}"
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                w3 = Web3(HTTPProvider(url, request_kwargs={"timeout": 2}))
                if w3.is_connected():
                    self.w3 = w3
                    return
            except Exception:
                pass
            time.sleep(0.1)
        raise RuntimeError("anvil failed to start")

    def _stop_anvil(self) -> None:
        if self._anvil is not None:
            self._anvil.terminate()
            try:
                self._anvil.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._anvil.kill()
            self._anvil = None

    # ------------------------------------------------------------------ deploy/setup
    def _set_balance(self, addr: str, wei: int) -> None:
        self.w3.provider.make_request("anvil_setBalance", [addr, hex(wei)])

    def _deploy(self) -> None:
        assert self.w3 is not None and self._abi is not None and self._bytecode is not None
        self._set_balance(self.admin_address, self.spec.deploy_value_wei + 10**21)
        contract_factory = self.w3.eth.contract(abi=self._abi, bytecode=self._bytecode)
        ctor_abi = next((e for e in self._abi if e.get("type") == "constructor"), None)
        ctor_inputs = (ctor_abi or {}).get("inputs", [])
        resolved_args: list[Any] = []
        for inp, raw_arg in zip(ctor_inputs, self.spec.deploy_args):
            resolved_args.append(self._resolve_arg(raw_arg, inp["type"]))
        if len(resolved_args) != len(ctor_inputs):
            raise ValueError(
                f"deploy_args length mismatch: spec gave {len(self.spec.deploy_args)} "
                f"but constructor expects {len(ctor_inputs)}"
            )
        tx_hash = contract_factory.constructor(*resolved_args).transact({
            "from": self.admin_address,
            "value": self.spec.deploy_value_wei,
        })
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        if receipt.status != 1:
            raise RuntimeError("deploy failed")
        self.contract = self.w3.eth.contract(address=receipt.contractAddress, abi=self._abi)

    def _deploy_tokens(self) -> None:
        """Deploy each MockERC20 + mint initial balances. Approvals come later."""
        if not self.spec.tokens:
            return
        for tdef in self.spec.tokens:
            factory = self.w3.eth.contract(abi=self._erc20_abi, bytecode=self._erc20_bytecode)
            tx = factory.constructor(tdef.name, tdef.name, tdef.decimals).transact(
                {"from": self.admin_address}
            )
            rcpt = self.w3.eth.wait_for_transaction_receipt(tx)
            token = self.w3.eth.contract(address=rcpt.contractAddress, abi=self._erc20_abi)
            self._token_contracts[tdef.name] = token
            self._token_addresses[tdef.name] = rcpt.contractAddress
            for role_name, amount in tdef.initial_balances.items():
                if role_name == "__admin__":
                    target = self.admin_address
                else:
                    target = self.role_addresses.get(role_name)
                    if target is None:
                        raise KeyError(f"token {tdef.name} initial_balance for unknown role {role_name}")
                tx = token.functions.mint(target, amount).transact({"from": self.admin_address})
                self.w3.eth.wait_for_transaction_receipt(tx)

    def _approve_tokens(self) -> None:
        """Auto-approve main contract for max from every role + admin."""
        for tname, token in self._token_contracts.items():
            for addr in [self.admin_address] + list(self.role_addresses.values()):
                tx = token.functions.approve(self.contract.address, MAX_UINT256).transact(
                    {"from": addr}
                )
                self.w3.eth.wait_for_transaction_receipt(tx)

    def _run_setup_calls(self) -> None:
        for action in self.spec.setup_calls:
            target_contract, target_abi, fn_name = self._resolve_target(action.function)
            args, tx_value = self._build_call_with_abi(action, fn_name, target_abi)
            tx = target_contract.functions[fn_name](*args).transact(
                {"from": self.admin_address, "value": tx_value}
            )
            self.w3.eth.wait_for_transaction_receipt(tx)

    def setup(self) -> None:
        self._compile()
        self._start_anvil()
        for r in self.spec.roles:
            self._set_balance(r.address, r.initial_eth)
        self._deploy_tokens()  # tokens first; main contract may reference them in constructor
        self._deploy()
        self._approve_tokens()
        self._run_setup_calls()

    def close(self) -> None:
        self._stop_anvil()

    def __enter__(self):
        self.setup()
        return self

    def __exit__(self, *exc):
        self.close()

    # ------------------------------------------------------------------ snapshot
    def _snapshot(self) -> str:
        return self.w3.provider.make_request("evm_snapshot", [])["result"]

    def _revert(self, snap_id: str) -> None:
        self.w3.provider.make_request("evm_revert", [snap_id])

    def _snapshot_balances(self) -> dict[str, dict[str, int]]:
        """Per-role + main-contract asset balances. Contract is keyed `__contract__`."""
        out: dict[str, dict[str, int]] = {}
        for r in self.spec.roles:
            assets: dict[str, int] = {"ETH": self.w3.eth.get_balance(r.address)}
            for tname, token in self._token_contracts.items():
                assets[tname] = token.functions.balanceOf(r.address).call()
            out[r.name] = assets
        contract_assets: dict[str, int] = {
            "ETH": self.w3.eth.get_balance(self.contract.address)
        }
        for tname, token in self._token_contracts.items():
            contract_assets[tname] = token.functions.balanceOf(self.contract.address).call()
        out["__contract__"] = contract_assets
        return out

    # ------------------------------------------------------------------ args
    def _resolve_address_arg(self, v: Any) -> str:
        if isinstance(v, str):
            if v.startswith("@@"):
                tname = v[2:]
                if tname in ("self", "Self", "contract"):
                    return self.contract.address
                if tname in self._token_addresses:
                    return self._token_addresses[tname]
                raise KeyError(f"unknown token reference: {v}")
            if v.startswith("@"):
                role_name = _strip_role_suffix(v)
                if role_name in self.role_addresses:
                    return self.role_addresses[role_name]
                raise KeyError(f"unknown role reference: {v}")
        return v

    def _resolve_int_arg(self, v: Any) -> int:
        if isinstance(v, bool):
            raise TypeError("bool not int")
        if isinstance(v, int):
            return v
        if isinstance(v, str):
            return int(v.replace("_", ""))
        raise TypeError(f"not int: {v!r}")

    def _resolve_arg(self, value: Any, sol_type: str) -> Any:
        if sol_type == "address":
            return self._resolve_address_arg(value)
        if sol_type.startswith("uint") or sol_type.startswith("int"):
            return self._resolve_int_arg(value)
        if sol_type == "bool":
            return bool(value)
        if sol_type == "bytes" or sol_type.startswith("bytes"):
            if isinstance(value, bytes):
                return value
            if isinstance(value, str):
                if value.startswith("0x"):
                    return bytes.fromhex(value[2:])
                return value.encode()
            return b""
        return value

    def _resolve_target(self, function: str) -> tuple[Contract, list[dict], str]:
        """Map 'fn' -> (main contract, ABI, fn) and 'TokenName.fn' -> (token, ABI, fn)."""
        if "." in function:
            tname, fn = function.split(".", 1)
            token = self._token_contracts.get(tname)
            if token is None:
                raise KeyError(f"unknown token in action: {tname!r}")
            return token, self._erc20_abi, fn
        return self.contract, self._abi, function

    def _build_call_with_abi(
        self, action: Action, fn_name: str, abi: list[dict]
    ) -> tuple[list[Any], int]:
        fn_abi = next(
            (e for e in abi if e.get("type") == "function" and e["name"] == fn_name),
            None,
        )
        if fn_abi is None:
            raise KeyError(f"function not in ABI: {fn_name}")
        args = dict(action.args)
        tx_value = 0
        if "value_wei" in args:
            tx_value = self._resolve_int_arg(args.pop("value_wei"))
        positional: list[Any] = []
        for inp in fn_abi.get("inputs", []):
            name = inp["name"]
            chosen = None
            for cand in (name, f"{name}_wei"):
                if cand in args:
                    chosen = args.pop(cand)
                    break
            if chosen is None:
                raise KeyError(
                    f"missing arg {name!r} for {action.function}; got {list(action.args)}"
                )
            positional.append(self._resolve_arg(chosen, inp["type"]))
        if args:
            raise KeyError(f"unused args {list(args)} for {action.function}")
        return positional, tx_value

    def _build_call(self, action: Action) -> tuple[Contract, list[dict], str, list[Any], int]:
        target, abi, fn_name = self._resolve_target(action.function)
        args, tx_value = self._build_call_with_abi(action, fn_name, abi)
        return target, abi, fn_name, args, tx_value

    # ------------------------------------------------------------------ pseudo-actions
    def _is_pseudo(self, action_name: str) -> bool:
        return action_name in self.PSEUDO_ACTIONS

    def _dispatch_pseudo(self, action: Action) -> str:
        if action.function == "wait":
            self.w3.provider.make_request("evm_mine", [])
            return "wait[mine]"
        if action.function == "advance_time":
            seconds = self._resolve_int_arg(action.args.get("seconds", 1))
            self.w3.provider.make_request("evm_increaseTime", [seconds])
            self.w3.provider.make_request("evm_mine", [])
            return f"advance_time[+{seconds}s]"
        if action.function == "simulate_price_drop":
            factor = float(action.args.get("factor", 1.0))
            current = self.contract.functions.price().call()
            new_price = int(current * factor)
            tx = self.contract.functions.setPrice(new_price).transact({"from": self.admin_address})
            self.w3.eth.wait_for_transaction_receipt(tx)
            return f"simulate_price_drop[factor={factor}, price={current}->{new_price}]"
        if action.function == "distribute_rewards":
            amount = self._resolve_int_arg(action.args.get("amount_wei", 0))
            self._set_balance(self.admin_address, amount + 10**21)
            tx = self.contract.functions.distribute().transact(
                {"from": self.admin_address, "value": amount}
            )
            self.w3.eth.wait_for_transaction_receipt(tx)
            return f"distribute_rewards[amount={amount}]"
        raise KeyError(f"unknown pseudo-action: {action.function}")

    # ------------------------------------------------------------------ exec
    def _exec_action(self, role: Role, action: Action, log: list[str], reverts: list[str]) -> None:
        try:
            if self._is_pseudo(action.function):
                line = self._dispatch_pseudo(action)
                log.append(f"[env] {line}")
                return
            target, abi, fn_name, args, tx_value = self._build_call(action)
            tx_hash = target.functions[fn_name](*args).transact(
                {"from": role.address, "value": tx_value}
            )
            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
            if receipt.status != 1:
                reverts.append(f"{role.name}.{action.function}: tx status 0")
                log.append(f"[{role.name}] REVERT {action.function}({args}, value={tx_value})")
            else:
                log.append(f"[{role.name}] {action.function}({args}, value={tx_value})")
        except ContractLogicError as e:
            reverts.append(f"{role.name}.{action.function}: {e}")
            log.append(f"[{role.name}] REVERT {action.function} ({e})")
        except Exception as e:
            reverts.append(f"{role.name}.{action.function}: {e}")
            log.append(f"[{role.name}] ERROR {action.function} ({e})")

    def execute_scenario(self, strategies: dict[str, Strategy]) -> ExecutionResult:
        snap = self._snapshot()
        log: list[str] = []
        reverts: list[str] = []
        initial = self._snapshot_balances()
        try:
            # Gather all (role, action) pairs and sort by (effective_phase, role_index, action_index).
            # Effective phase: action.phase if set, else role.default_phase if >= 0, else role index.
            schedule: list[tuple[int, int, int, Role, Action]] = []
            for role_idx, role in enumerate(self.spec.roles):
                strat = strategies.get(role.name)
                if strat is None:
                    continue
                role_default = role.default_phase if role.default_phase >= 0 else role_idx
                for action_idx, action in enumerate(strat.actions):
                    phase = action.phase if action.phase is not None else role_default
                    schedule.append((phase, role_idx, action_idx, role, action))
            schedule.sort(key=lambda t: (t[0], t[1], t[2]))
            for _, _, _, role, action in schedule:
                self._exec_action(role, action, log, reverts)
            final = self._snapshot_balances()
            deltas = {
                r: {a: final[r][a] - initial[r][a] for a in final[r]}
                for r in final
            }
            return ExecutionResult(
                asset_deltas=deltas,
                final_balances=final,
                initial_balances=initial,
                action_log=log,
                reverts=reverts,
            )
        finally:
            self._revert(snap)
