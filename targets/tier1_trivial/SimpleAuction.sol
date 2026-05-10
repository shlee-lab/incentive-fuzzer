// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// SimpleAuction
///
/// Honest behavior:
/// - Bidders bid; each new bid must strictly exceed the previous high. The
///   previously-leading bidder's funds are queued for withdrawal via
///   `pendingReturns`.
/// - When the seller calls `settle`, the winning bid is paid out to the seller.
///
/// Implicit role-separation assumption (NOT enforced):
/// - Seller and Bidder are distinct parties. The contract never checks that
///   `msg.sender != seller` in `bid`, nor that `highBidder != seller` in
///   `settle`.
///
/// Implementation bug:
/// - In `settle`, the winning bid is sent to the seller AND a refund of the
///   same amount is queued back into `pendingReturns[highBidder]`. The second
///   line was meant to refund a stale prior bidder but is wired to the wrong
///   account; the actual previous bidder was already credited inside `bid`.
///
/// Expected deviation found by the fuzzer:
/// - The Seller, who is also allowed to bid, places a bid that becomes the
///   highBid, then settles, then withdraws. They collect the bid amount twice
///   (once via the seller payout, once via the queued refund), draining the
///   contract's prefunded escrow for a clean profit.
contract SimpleAuction {
    address public seller;
    uint256 public reserve;
    address public highBidder;
    uint256 public highBid;
    bool public settled;
    mapping(address => uint256) public pendingReturns;

    constructor(address _seller, uint256 _reserve) payable {
        seller = _seller;
        reserve = _reserve;
    }

    function bid() external payable {
        require(!settled, "settled");
        require(msg.value > highBid, "bid not higher");
        require(msg.value >= reserve, "below reserve");
        if (highBidder != address(0)) {
            pendingReturns[highBidder] += highBid;
        }
        highBidder = msg.sender;
        highBid = msg.value;
    }

    function withdraw() external {
        uint256 amount = pendingReturns[msg.sender];
        pendingReturns[msg.sender] = 0;
        if (amount > 0) {
            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            require(ok, "withdraw failed");
        }
    }

    function settle() external {
        require(!settled, "already settled");
        settled = true;
        if (highBidder == address(0)) return;
        (bool ok, ) = payable(seller).call{value: highBid}("");
        require(ok, "pay seller failed");
        pendingReturns[highBidder] += highBid; // BUG
    }

    receive() external payable {}
}
