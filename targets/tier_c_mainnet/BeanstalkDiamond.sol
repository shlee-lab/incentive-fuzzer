// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// BeanstalkDiamond ABI port for fork-mode attach
/// (0xC1E088fC1323b20BCBee9bd1B9fC9546db5624C5).
///
/// Real Beanstalk is an EIP-2535 Diamond with many facets:
/// SiloFacet, GovernanceFacet, SeasonFacet, FieldFacet, MarketplaceFacet,
/// FundraiserFacet, etc. We declare ONLY the function selectors the
/// fuzzer needs to model the governance-drain attack class. Bodies are
/// stubs — at runtime we attach this ABI to the real Diamond address
/// and the calls are routed by the Diamond's fallback to the correct
/// facet implementation.
///
/// Selectors covered (subset matching the April 2022 governance attack):
///   Silo facet:
///     - deposit(address, uint256)            stake LP for stalk voting weight
///     - withdraw(address, uint32[], uint256[]) unstake
///     - balanceOfStalk(address)              voting power
///   Governance facet:
///     - propose(bytes32, bytes calldata, uint8, bytes calldata) introduce BIP
///     - vote(uint32)                         vote yes with current stalk
///     - emergencyCommit(uint32)              execute (the attacker's path)
contract BeanstalkDiamond {
    // Silo facet — deposit/withdraw LP tokens for stalk (voting weight).
    function deposit(address token, uint256 amount) external {}
    function withdraw(address token, uint32[] calldata seasons, uint256[] calldata amounts) external {}
    function balanceOfStalk(address account) external view returns (uint256) { return 0; }

    // Governance facet — propose / vote / commit BIPs.
    function propose(bytes32 bipHash, bytes calldata bipData, uint8 facetType, bytes calldata facetData)
        external returns (uint32)
    {
        return 0;
    }
    function vote(uint32 bip) external {}
    function commit(uint32 bip) external {}
    function emergencyCommit(uint32 bip) external {}
    function unvote(uint32 bip) external {}
}
