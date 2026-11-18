// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title PoC — Zircuit Finance VaultComposer: queued-redeem "txFee" is paid to the keeper, not refunded to the user
/// @notice Fork test against the LIVE Base deployment of the USDC VaultComposer.
///         A user enqueues a cross-chain redemption paying exactly what the official
///         SDK charges: the LayerZero quote + the standard 30% fee buffer.
///         The contract stores the buffer as `txFee`; when the keeper processes the
///         entry, the outbound send is paid from the quote only and the full `txFee`
///         is transferred to the keeper. The user receives nothing back.
///
/// Run:  forge test --fork-url https://base-rpc.publicnode.com -vvv

interface Vm {
    function deal(address account, uint256 amount) external;
    function prank(address sender) external;
    function store(address target, bytes32 slot, bytes32 value) external;
    function load(address target, bytes32 slot) external returns (bytes32);
}

struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct QueueEntry {
    address initiator;
    uint256 shareAmount;
    SendParam sendParam;
    uint256 fee;
    uint256 txFee;
    address refundAddress;
    bool fulfilled;
    bool canceled;
}

interface IVaultComposer {
    function quoteSend(address _from, address _targetOFT, uint256 _vaultInAmount, SendParam memory _sendParam)
        external
        view
        returns (MessagingFee memory);
    function redeemAndSend(uint256 _shareAmount, SendParam memory _sendParam, address _refundAddress)
        external
        payable;
    function processWithdrawals(uint256[] calldata _ids, uint256[] calldata _extraFees) external payable;
    function getWithdrawalQueueLength() external view returns (uint256);
    function getWithdrawalQueueEntry(uint256 _index) external view returns (QueueEntry memory);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IVault {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function previewRedeem(uint256 shares) external view returns (uint256);
}

contract TxFeeDiversionTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Live Base deployments (USDC cluster) — SDK registry @zircuit/ovault-evm
    IVaultComposer constant COMPOSER = IVaultComposer(0xBb801ED781dF31F660cC743bEf7Bb9D04B030923);
    IVault constant VAULT = IVault(0x03067bbD0d41E3Fe4A0bb6ca67c99e7352Da4CAE);
    address constant UNDERLYING_OFT = 0xd7aBC360dfcF1B6dD0a03138235e12A2bc1c1C8B;
    uint32 constant ETHEREUM_EID = 30101;

    // OpenZeppelin v5 AccessControl (ERC-7201) storage location, from the deployed source
    bytes32 constant ACCESS_CONTROL_LOCATION = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;
    // OpenZeppelin v5 ERC20 (ERC-7201) storage location, from the deployed source:
    // struct ERC20Storage { mapping _balances (offset 0); mapping _allowances (offset 1); uint256 _totalSupply (offset 2); ... }
    bytes32 constant ERC20_LOCATION = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    /// @dev Mints vault shares to `account` by writing the ERC20 storage directly (fork-only).
    function _dealShares(address account, uint256 amount) internal {
        bytes32 balSlot = keccak256(abi.encode(account, ERC20_LOCATION));
        uint256 oldBal = uint256(vm.load(address(VAULT), balSlot));
        vm.store(address(VAULT), balSlot, bytes32(amount));
        bytes32 tsSlot = bytes32(uint256(ERC20_LOCATION) + 2);
        uint256 ts = uint256(vm.load(address(VAULT), tsSlot));
        vm.store(address(VAULT), tsSlot, bytes32(ts + amount - oldBal));
    }

    address user = address(0xA11CE);
    address keeper = address(0xBEEF01);

    function _grantWithdrawalManager(address account) internal {
        bytes32 role = keccak256("WITHDRAWAL_MANAGER");
        bytes32 roleDataSlot = keccak256(abi.encode(role, ACCESS_CONTROL_LOCATION));
        bytes32 memberSlot = keccak256(abi.encode(account, roleDataSlot));
        vm.store(address(COMPOSER), memberSlot, bytes32(uint256(1)));
    }

    function test_txFee_goes_to_keeper_not_user() public {
        uint256 shares = 10_000_000; // 10 vault shares (6 decimals)

        // --- setup: user holds shares and ETH -------------------------------
        vm.deal(user, 10 ether);
        _dealShares(user, shares);
        require(VAULT.balanceOf(user) == shares, "deal shares failed");

        // --- build the send param exactly like the official SDK does --------
        uint256 expectedOut = VAULT.previewRedeem(shares);
        SendParam memory sp = SendParam({
            dstEid: ETHEREUM_EID,
            to: bytes32(uint256(uint160(user))),
            amountLD: shares,
            minAmountLD: (expectedOut * 99) / 100, // 1% slippage, the SDK default
            extraOptions: hex"0003", // production entries carry the bare type-3 header
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory quote = COMPOSER.quoteSend(user, UNDERLYING_OFT, shares, sp);
        uint256 fee = quote.nativeFee;
        require(fee > 0, "quote is zero");
        uint256 buffer = (fee * 30) / 100; // the official +30% fee buffer
        uint256 totalPaid = fee + buffer;

        // --- enqueue the redemption -----------------------------------------
        vm.prank(user);
        VAULT.approve(address(COMPOSER), shares);

        uint256 id = COMPOSER.getWithdrawalQueueLength();
        vm.prank(user);
        COMPOSER.redeemAndSend{value: totalPaid}(shares, sp, user);

        QueueEntry memory entry = COMPOSER.getWithdrawalQueueEntry(id);
        require(entry.initiator == user, "wrong initiator");
        require(entry.fee == fee, "stored fee != quote");
        require(entry.txFee == buffer, "stored txFee != 30% buffer");
        require(!entry.fulfilled && !entry.canceled, "entry should be pending");

        // --- keeper processes the entry --------------------------------------
        _grantWithdrawalManager(keeper);
        require(COMPOSER.hasRole(keccak256("WITHDRAWAL_MANAGER"), keeper), "role grant failed");

        uint256 keeperBefore = keeper.balance;
        uint256 userBefore = user.balance;

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory extraFees = new uint256[](1);
        extraFees[0] = 0;

        vm.prank(keeper);
        COMPOSER.processWithdrawals(ids, extraFees);

        entry = COMPOSER.getWithdrawalQueueEntry(id);
        require(entry.fulfilled, "entry not fulfilled");

        // --- the assertions that prove the finding ---------------------------
        // 1. The keeper received the user's entire 30% buffer.
        require(keeper.balance - keeperBefore == buffer, "keeper did not receive exactly the txFee");
        // 2. The user received nothing back: the surplus over the real fee is gone.
        require(user.balance == userBefore, "user unexpectedly refunded");
    }
}
