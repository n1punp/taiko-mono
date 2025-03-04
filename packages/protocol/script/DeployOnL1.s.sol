// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/
//
//   Email: security@taiko.xyz
//   Website: https://taiko.xyz
//   GitHub: https://github.com/taikoxyz
//   Discord: https://discord.gg/taikoxyz
//   Twitter: https://twitter.com/taikoxyz
//   Blog: https://mirror.xyz/labs.taiko.eth
//   Youtube: https://www.youtube.com/@taikoxyz

pragma solidity 0.8.24;

import "@openzeppelin/contracts/utils/Strings.sol";

import "../contracts/L1/TaikoToken.sol";
import "../contracts/L1/TaikoL1.sol";
import "../contracts/L1/provers/GuardianProver.sol";
import "../contracts/L1/tiers/TaikoA6TierProvider.sol";
import "../contracts/L1/tiers/OptimisticTierProvider.sol";
import "../contracts/L1/hooks/AssignmentHook.sol";
import "../contracts/L1/gov/TaikoTimelockController.sol";
import "../contracts/L1/gov/TaikoGovernor.sol";
import "../contracts/bridge/Bridge.sol";
import "../contracts/tokenvault/ERC20Vault.sol";
import "../contracts/tokenvault/ERC1155Vault.sol";
import "../contracts/tokenvault/ERC721Vault.sol";
import "../contracts/signal/SignalService.sol";
import "../contracts/automata-attestation/AutomataDcapV3Attestation.sol";
import "../contracts/automata-attestation/utils/SigVerifyLib.sol";
import "../contracts/automata-attestation/lib/PEMCertChainLib.sol";
import "../contracts/verifiers/PseZkVerifier.sol";
import "../contracts/verifiers/SgxVerifier.sol";
import "../contracts/verifiers/SgxAndZkVerifier.sol";
import "../contracts/verifiers/GuardianVerifier.sol";
import "../test/common/erc20/FreeMintERC20.sol";
import "../test/common/erc20/MayFailFreeMintERC20.sol";
import "../test/DeployCapability.sol";

// Actually this one is deployed already on mainnets, but we are now deploying our own (non vi-ir)
// version. For mainnet, it is easier to go with either this:
// https://github.com/daimo-eth/p256-verifier or this:
// https://github.com/rdubois-crypto/FreshCryptoLib
import { P256Verifier } from "p256-verifier/src/P256Verifier.sol";

/// @title DeployOnL1
/// @notice This script deploys the core Taiko protocol smart contract on L1,
/// initializing the rollup.
contract DeployOnL1 is DeployCapability {
    uint256 public constant NUM_GUARDIANS = 5;

    address public constant MAINNET_SECURITY_COUNCIL = 0x7C50d60743D3FCe5a39FdbF687AFbAe5acFF49Fd;

    address securityCouncil =
        block.chainid == 1 ? MAINNET_SECURITY_COUNCIL : vm.envAddress("SECURITY_COUNCIL");

    modifier broadcast() {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        require(privateKey != 0, "invalid priv key");
        vm.startBroadcast();
        _;
        vm.stopBroadcast();
    }

    function run() external broadcast {
        addressNotNull(vm.envAddress("TAIKO_L2_ADDRESS"), "TAIKO_L2_ADDRESS");
        addressNotNull(vm.envAddress("L2_SIGNAL_SERVICE"), "L2_SIGNAL_SERVICE");
        require(vm.envBytes32("L2_GENESIS_HASH") != 0, "L2_GENESIS_HASH");

        // ---------------------------------------------------------------
        // Deploy shared contracts
        (address sharedAddressManager, address timelock) = deploySharedContracts();
        console2.log("sharedAddressManager: ", sharedAddressManager);
        console2.log("timelock: ", timelock);
        // ---------------------------------------------------------------
        // Deploy rollup contracts
        address rollupAddressManager = deployRollupContracts(sharedAddressManager, timelock);

        // ---------------------------------------------------------------
        // Signal service need to authorize the new rollup
        address signalServiceAddr =
            AddressManager(sharedAddressManager).getAddress(uint64(block.chainid), "signal_service");
        addressNotNull(signalServiceAddr, "signalServiceAddr");
        SignalService signalService = SignalService(signalServiceAddr);

        address taikoL1Addr =
            AddressManager(rollupAddressManager).getAddress(uint64(block.chainid), "taiko");
        addressNotNull(taikoL1Addr, "taikoL1Addr");
        TaikoL1 taikoL1 = TaikoL1(payable(taikoL1Addr));

        uint64 l2ChainId = taikoL1.getConfig().chainId;
        require(l2ChainId != block.chainid, "same chainid");

        console2.log("------------------------------------------");
        console2.log("msg.sender: ", msg.sender);
        console2.log("address(this): ", address(this));
        console2.log("signalService.owner(): ", signalService.owner());
        console2.log("------------------------------------------");

        if (signalService.owner() == address(this)) {
            signalService.transferOwnership(timelock);
        } else {
            console2.log("------------------------------------------");
            console2.log("Warning - you need to transact manually:");
            console2.log("signalService.authorize(taikoL1Addr, bytes32(block.chainid))");
            console2.log("- signalService : ", signalServiceAddr);
            console2.log("- taikoL1Addr   : ", taikoL1Addr);
            console2.log("- chainId       : ", block.chainid);
        }

        // ---------------------------------------------------------------
        // Register shared contracts in the new rollup
        copyRegister(rollupAddressManager, sharedAddressManager, "taiko_token");
        copyRegister(rollupAddressManager, sharedAddressManager, "signal_service");
        copyRegister(rollupAddressManager, sharedAddressManager, "bridge");

        address proposer = vm.envAddress("PROPOSER");
        if (proposer != address(0)) {
            register(rollupAddressManager, "proposer", proposer);
        }

        address proposerOne = vm.envAddress("PROPOSER_ONE");
        if (proposerOne != address(0)) {
            register(rollupAddressManager, "proposer_one", proposerOne);
        }

        // ---------------------------------------------------------------
        // Register L2 addresses
        register(rollupAddressManager, "taiko", vm.envAddress("TAIKO_L2_ADDRESS"), l2ChainId);
        register(
            rollupAddressManager, "signal_service", vm.envAddress("L2_SIGNAL_SERVICE"), l2ChainId
        );

        // ---------------------------------------------------------------
        // Deploy other contracts
        deployAuxContracts();

        if (AddressManager(sharedAddressManager).owner() == msg.sender) {
            AddressManager(sharedAddressManager).transferOwnership(timelock);
            console2.log("** sharedAddressManager ownership transferred to timelock:", timelock);
        }

        AddressManager(rollupAddressManager).transferOwnership(timelock);
        console2.log("** rollupAddressManager ownership transferred to timelock:", timelock);
    }

    function deploySharedContracts()
        internal
        returns (address sharedAddressManager, address timelock)
    {
        sharedAddressManager = vm.envAddress("SHARED_ADDRESS_MANAGER");
        if (sharedAddressManager != address(0)) {
            return (sharedAddressManager, vm.envAddress("TIMELOCK_CONTROLLER"));
        }

        // Deploy the timelock
        timelock = deployProxy({
            name: "timelock_controller",
            impl: address(new TaikoTimelockController()),
            data: abi.encodeCall(TaikoTimelockController.init, (7 days))
        });

        sharedAddressManager = deployProxy({
            name: "shared_address_manager",
            impl: address(new AddressManager()),
            data: abi.encodeCall(AddressManager.init, ())
        });

        address taikoToken = deployProxy({
            name: "taiko_token",
            impl: address(new TaikoToken()),
            data: abi.encodeCall(
                TaikoToken.init,
                (
                    vm.envString("TAIKO_TOKEN_NAME"),
                    vm.envString("TAIKO_TOKEN_SYMBOL"),
                    vm.envAddress("TAIKO_TOKEN_PREMINT_RECIPIENT")
                )
                ),
            registerTo: sharedAddressManager,
            owner: timelock
        });

        address governor = deployProxy({
            name: "taiko_governor",
            impl: address(new TaikoGovernor()),
            data: abi.encodeCall(
                TaikoGovernor.init,
                (IVotesUpgradeable(taikoToken), TimelockControllerUpgradeable(payable(timelock)))
                ),
            registerTo: address(0),
            owner: timelock
        });

        // Setup time lock roles
        TaikoTimelockController _timelock = TaikoTimelockController(payable(timelock));
        // Only the governer can make proposals after holders voting.
        _timelock.grantRole(_timelock.PROPOSER_ROLE(), governor);
        _timelock.grantRole(_timelock.PROPOSER_ROLE(), securityCouncil);

        // Granting address(0) the executor role to allow open executation.
        _timelock.grantRole(_timelock.EXECUTOR_ROLE(), address(0));

        // Cancelling is not supported by the implementation by default, therefore, no need to set
        // up this role.
        // _timelock.grantRole(_timelock.CANCELLER_ROLE(), securityCouncil);

        _timelock.grantRole(_timelock.TIMELOCK_ADMIN_ROLE(), securityCouncil);
        _timelock.revokeRole(_timelock.TIMELOCK_ADMIN_ROLE(), address(this));
        _timelock.revokeRole(_timelock.TIMELOCK_ADMIN_ROLE(), msg.sender);

        _timelock.transferOwnership(securityCouncil);

        // Deploy Bridging contracts
        deployProxy({
            name: "signal_service",
            impl: address(new SignalService()),
            data: abi.encodeCall(SignalService.init, (sharedAddressManager)),
            registerTo: sharedAddressManager,
            owner: address(0)
        });

        deployProxy({
            name: "bridge",
            impl: address(new Bridge()),
            data: abi.encodeCall(Bridge.init, (sharedAddressManager)),
            registerTo: sharedAddressManager,
            owner: timelock
        });

        console2.log("------------------------------------------");
        console2.log(
            "Warning - you need to register *all* counterparty bridges to enable multi-hop bridging:"
        );
        console2.log(
            "sharedAddressManager.setAddress(remoteChainId, \"bridge\", address(remoteBridge))"
        );
        console2.log("- sharedAddressManager : ", sharedAddressManager);

        // Deploy Vaults
        deployProxy({
            name: "erc20_vault",
            impl: address(new ERC20Vault()),
            data: abi.encodeCall(BaseVault.init, (sharedAddressManager)),
            registerTo: sharedAddressManager,
            owner: timelock
        });

        deployProxy({
            name: "erc721_vault",
            impl: address(new ERC721Vault()),
            data: abi.encodeCall(BaseVault.init, (sharedAddressManager)),
            registerTo: sharedAddressManager,
            owner: timelock
        });

        deployProxy({
            name: "erc1155_vault",
            impl: address(new ERC1155Vault()),
            data: abi.encodeCall(BaseVault.init, (sharedAddressManager)),
            registerTo: sharedAddressManager,
            owner: timelock
        });

        console2.log("------------------------------------------");
        console2.log(
            "Warning - you need to register *all* counterparty vaults to enable multi-hop bridging:"
        );
        console2.log(
            "sharedAddressManager.setAddress(remoteChainId, \"erc20_vault\", address(remoteERC20Vault))"
        );
        console2.log(
            "sharedAddressManager.setAddress(remoteChainId, \"erc721_vault\", address(remoteERC721Vault))"
        );
        console2.log(
            "sharedAddressManager.setAddress(remoteChainId, \"erc1155_vault\", address(remoteERC1155Vault))"
        );
        console2.log("- sharedAddressManager : ", sharedAddressManager);

        // Deploy Bridged token implementations
        register(sharedAddressManager, "bridged_erc20", address(new BridgedERC20()));
        register(sharedAddressManager, "bridged_erc721", address(new BridgedERC721()));
        register(sharedAddressManager, "bridged_erc1155", address(new BridgedERC1155()));
    }

    function deployRollupContracts(
        address _sharedAddressManager,
        address timelock
    )
        internal
        returns (address rollupAddressManager)
    {
        addressNotNull(_sharedAddressManager, "sharedAddressManager");
        addressNotNull(timelock, "timelock");

        rollupAddressManager = deployProxy({
            name: "rollup_address_manager",
            impl: address(new AddressManager()),
            data: abi.encodeCall(AddressManager.init, ())
        });

        deployProxy({
            name: "taiko",
            impl: address(new TaikoL1()),
            data: abi.encodeCall(TaikoL1.init, (rollupAddressManager, vm.envBytes32("L2_GENESIS_HASH"))),
            registerTo: rollupAddressManager,
            owner: timelock
        });

        deployProxy({
            name: "assignment_hook",
            impl: address(new AssignmentHook()),
            data: abi.encodeCall(AssignmentHook.init, (rollupAddressManager)),
            registerTo: address(0),
            owner: timelock
        });

        address tierProvider;
        if (vm.envBool("OPTIMISTIC_TIER_PROVIDER")) {
            tierProvider = address(new OptimisticTierProvider());
        } else {
            tierProvider = address(new TaikoA6TierProvider());
        }

        deployProxy({
            name: "tier_provider",
            impl: tierProvider,
            data: abi.encodeCall(TaikoA6TierProvider.init, ()),
            registerTo: rollupAddressManager,
            owner: timelock
        });

        deployProxy({
            name: "tier_guardian",
            impl: address(new GuardianVerifier()),
            data: abi.encodeCall(GuardianVerifier.init, (rollupAddressManager)),
            registerTo: rollupAddressManager,
            owner: timelock
        });

        deployProxy({
            name: "tier_sgx",
            impl: address(new SgxVerifier()),
            data: abi.encodeCall(SgxVerifier.init, (rollupAddressManager)),
            registerTo: rollupAddressManager,
            owner: timelock
        });

        deployProxy({
            name: "tier_sgx_and_pse_zkevm",
            impl: address(new SgxAndZkVerifier()),
            data: abi.encodeCall(SgxAndZkVerifier.init, (rollupAddressManager)),
            registerTo: rollupAddressManager,
            owner: timelock
        });

        address pseZkVerifier = deployProxy({
            name: "tier_pse_zkevm",
            impl: address(new PseZkVerifier()),
            data: abi.encodeCall(PseZkVerifier.init, (rollupAddressManager)),
            registerTo: rollupAddressManager,
            owner: timelock
        });

        address[] memory plonkVerifiers = new address[](1);
        plonkVerifiers[0] = deployPseZkEvmVerifier("contracts/verifiers/PlonkVerifier.yulp");

        for (uint16 i = 0; i < plonkVerifiers.length; ++i) {
            register(
                rollupAddressManager,
                string(abi.encodePacked(PseZkVerifier(pseZkVerifier).getVerifierName(i))),
                plonkVerifiers[i]
            );
        }

        address guardianProver = deployProxy({
            name: "guardian_prover",
            impl: address(new GuardianProver()),
            data: abi.encodeCall(GuardianProver.init, (rollupAddressManager)),
            registerTo: rollupAddressManager,
            owner: address(0)
        });

        address[] memory guardians = vm.envAddress("GUARDIAN_PROVERS", ",");
        uint8 minGuardians = uint8(vm.envUint("MIN_GUARDIANS"));
        GuardianProver(guardianProver).setGuardians(guardians, minGuardians);
        GuardianProver(guardianProver).transferOwnership(timelock);

        // No need to proxy these, because they are 3rd party. If we want to modify, we simply
        // change the registerAddress("automata_dcap_attestation", address(attestation));
        P256Verifier p256Verifier = new P256Verifier();
        SigVerifyLib sigVerifyLib = new SigVerifyLib(address(p256Verifier));
        PEMCertChainLib pemCertChainLib = new PEMCertChainLib();
        AutomataDcapV3Attestation automateDcapV3Attestation =
            new AutomataDcapV3Attestation(address(sigVerifyLib), address(pemCertChainLib));

        register(
            rollupAddressManager, "automata_dcap_attestation", address(automateDcapV3Attestation)
        );
    }

    function deployAuxContracts() private {
        address horseToken = address(new FreeMintERC20("Horse Token", "HORSE"));
        console2.log("HorseToken", horseToken);

        address bullToken = address(new MayFailFreeMintERC20("Bull Token", "BULL"));
        console2.log("BullToken", bullToken);
    }

    // Since the auto-generated solidity PlonkVerifier is too big for foundry
    // to compile, so we still keep the file name as `PlonkVerifier.yulp` and
    // use this function to compile it manually.
    function deployPseZkEvmVerifier(string memory verifierContractPath)
        private
        returns (address addr)
    {
        string[] memory cmds = new string[](3);
        cmds[0] = "bash";
        cmds[1] = "-c";
        cmds[2] = string.concat(
            vm.projectRoot(),
            "/bin/solc --bin ",
            string.concat(vm.projectRoot(), "/", verifierContractPath),
            " | grep -A1 Binary | tail -1"
        );

        bytes memory bytecode = vm.ffi(cmds);
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }

        addressNotNull(addr, "failed yul deployment");
        console2.log(verifierContractPath, addr);
    }

    function addressNotNull(address addr, string memory err) private pure {
        require(addr != address(0), err);
    }
}
