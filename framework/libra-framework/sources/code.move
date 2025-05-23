/// This module supports functionality related to code management.
module diem_framework::code {
    use std::string::String;
    use std::error;
    use std::signer;
    use std::vector;
    use diem_framework::util;
    use diem_framework::system_addresses;
    use diem_std::copyable_any::Any;
    use std::option::Option;
    use std::string;
    use ol_framework::testnet;

    // ----------------------------------------------------------------------
    // Code Publishing

    /// The package registry at the given address.
    struct PackageRegistry has key, store, drop {
        /// Packages installed at this address.
        packages: vector<PackageMetadata>,
    }

    /// Metadata for a package. All byte blobs are represented as base64-of-gzipped-bytes
    struct PackageMetadata has store, drop {
        /// Name of this package.
        name: String,
        /// The upgrade policy of this package.
        upgrade_policy: UpgradePolicy,
        /// The numbers of times this module has been upgraded. Also serves as the on-chain version.
        /// This field will be automatically assigned on successful upgrade.
        upgrade_number: u64,
        /// The source digest of the sources in the package. This is constructed by first building the
        /// sha256 of each individual source, than sorting them alphabetically, and sha256 them again.
        source_digest: String,
        /// The package manifest, in the Move.toml format. Gzipped text.
        manifest: vector<u8>,
        /// The list of modules installed by this package.
        modules: vector<ModuleMetadata>,
        /// Holds PackageDeps.
        deps: vector<PackageDep>,
        /// For future extension
        extension: Option<Any>
    }

    /// A dependency to a package published at address
    struct PackageDep has store, drop, copy {
        account: address,
        package_name: String
    }

    /// Metadata about a module in a package.
    struct ModuleMetadata has store, drop {
        /// Name of the module.
        name: String,
        /// Source text, gzipped String. Empty if not provided.
        source: vector<u8>,
        /// Source map, in compressed BCS. Empty if not provided.
        source_map: vector<u8>,
        /// For future extensions.
        extension: Option<Any>,
    }

    /// Describes an upgrade policy
    struct UpgradePolicy has store, copy, drop {
        policy: u8
    }

    /// Package contains duplicate module names with existing modules publised in other packages on this address
    const EMODULE_NAME_CLASH: u64 = 0x1;

    /// Cannot upgrade an immutable package
    const EUPGRADE_IMMUTABLE: u64 = 0x2;

    /// Cannot downgrade a package's upgradability policy
    const EUPGRADE_WEAKER_POLICY: u64 = 0x3;

    /// Cannot delete a module that was published in the same package
    const EMODULE_MISSING: u64 = 0x4;

    /// Dependency could not be resolved to any published package.
    const EPACKAGE_DEP_MISSING: u64 = 0x5;

    /// A dependency cannot have a weaker upgrade policy.
    const EDEP_WEAKER_POLICY: u64 = 0x6;

    /// A dependency to an `arbitrary` package must be on the same address.
    const EDEP_ARBITRARY_NOT_SAME_ADDRESS: u64 = 0x7;

    /// Creating a package with incompatible upgrade policy is disabled.
    const EINCOMPATIBLE_POLICY_DISABLED: u64 = 0x8;

    //////// 0L ////////
    /// Third party contracts can be published on testnet and layer 2. Libra, not blockchain.
    const ENOT_A_COMPUTE_PLATFORM: u64 = 0x9;

    /// Whether unconditional code upgrade with no compatibility check is allowed. This
    /// publication mode should only be used for modules which aren't shared with user others.
    /// The developer is responsible for not breaking memory layout of any resources he already
    /// stored on chain.
    public fun upgrade_policy_arbitrary(): UpgradePolicy {
        UpgradePolicy { policy: 0 }
    }

    /// Whether a compatibility check should be performed for upgrades. The check only passes if
    /// a new module has (a) the same public functions (b) for existing resources, no layout change.
    public fun upgrade_policy_compat(): UpgradePolicy {
        UpgradePolicy { policy: 1 }
    }

    /// Whether the modules in the package are immutable and cannot be upgraded.
    public fun upgrade_policy_immutable(): UpgradePolicy {
        UpgradePolicy { policy: 2 }
    }

    /// Whether the upgrade policy can be changed. In general, the policy can be only
    /// strengthened but not weakened.
    public fun can_change_upgrade_policy_to(from: UpgradePolicy, to: UpgradePolicy): bool {
        from.policy <= to.policy
    }

    /// Initialize package metadata for Genesis.
    fun initialize(diem_framework: &signer, package_owner: &signer, metadata: PackageMetadata)
    acquires PackageRegistry {
        system_addresses::assert_diem_framework(diem_framework);
        let addr = signer::address_of(package_owner);
        if (!exists<PackageRegistry>(addr)) {
            move_to(package_owner, PackageRegistry { packages: vector[metadata] })
        } else {
            vector::push_back(&mut borrow_global_mut<PackageRegistry>(addr).packages, metadata)
        }
    }

    // NOTE: we are allowing this to be a public function because
    // we need for @0x1 to be able to call this function from a tx script on
    // upgrades.

    /// Publishes a package at the given signer's address. The caller must provide package metadata describing the
    /// package.
    public fun publish_package(owner: &signer, pack: PackageMetadata, code:
    vector<vector<u8>>) acquires PackageRegistry {
        // Contract publishing is done by system resource addresses (0x1, 0x2,
        // etc.)
        // To defend the throughput and reliability of the chain, the layer 1
        // optimizes for the intended use of the chain (programming Libra)
        // versus generalized compute (which does not use Libra).
        // Despite there being no user deployment of modules, any user can craft
        // Move "transaction scripts" for custom workflows which use framework
        // smart contracts. Note that such transaction scripts can also be
        // executed in multisig and ownerless "resource accounts"
        // for community execution.
        // Third party modules are possible on L2 networks, and testnet.
        // If you need a specific functionality or program on the Layer 1,
        // submit a pull request for module "Ascension" (for more info see: https://www.youtube.com/watch?v=jDwqPCAw_7k).

        let addr = signer::address_of(owner);

        // If it is not a reserved address this must not be chain ID 1 (mainnet)
        assert!(
          is_policy_exempted_address(addr) ||
          testnet::is_testnet(),
          ENOT_A_COMPUTE_PLATFORM
          // Rise up this mornin',
          // Smiled with the risin' sun,
          // Three little birds
          // Pitch by my doorstep
          // Singin' sweet songs
          // Of melodies pure and true,
          // Sayin', ("This is my message to you-ou-ou:")
        );

        // including this for future compatibility.
        // only system accounts can publish so this is always a `false`
        // TODO: determine if this policy is necessary for system
        // upgrades or not. And second, determine if needed for user
        // testing.

        // if (!is_policy_exempted_address(addr)) { // wrapping this to prevent fat finger
        //   assert!(
        //       pack.upgrade_policy.policy > upgrade_policy_arbitrary().policy,
        //       error::invalid_argument(EINCOMPATIBLE_POLICY_DISABLED),
        //   );
        // };

        if (!exists<PackageRegistry>(addr)) {
            move_to(owner, PackageRegistry { packages: vector::empty() })
        };

        // Checks for valid dependencies to other packages
        let allowed_deps = check_dependencies(addr, &pack);

        // Check package against conflicts
        let module_names = get_module_names(&pack);

        // E.g (stdlib, diem-stdlib, libra-framework)
        let current_packages = &mut borrow_global_mut<PackageRegistry>(addr).packages;
        let current_package_len = vector::length(current_packages);

        let index = current_package_len;
        let i = 0;
        let upgrade_number = 0;
        // for every package (e.g. stdlib, libra-framework) we have installed (old)
        // let's check to see if the package can either:
        // a) be upgraded to new using same namespace
        // b) can coexist with new existing installation
        while (i < current_package_len) {
            let old = vector::borrow(current_packages, i);
            if (old.name == pack.name) {

                upgrade_number = old.upgrade_number + 1;

                // including this for future compatibility.
                // only system accounts can publish so this is always a `false`
                if (!is_policy_exempted_address(addr)) {
                  // check_upgradability(old, &pack, &module_names);
                };

                index = i;
            } else {
                check_coexistence(old, &module_names)
            };
            i = i + 1;
        };

        // Assign the upgrade counter.
        pack.upgrade_number = upgrade_number;

        // Update registry
        let policy = pack.upgrade_policy;
        if (index < current_package_len) {
            *vector::borrow_mut(current_packages, index) = pack
        } else {
            vector::push_back(current_packages, pack)
        };

        // Commit note: there is only this option since other `request_publish`
        // is deprecated
        request_publish_with_allowed_deps(addr, module_names, allowed_deps,code, policy.policy);
    }

    /// Same as `publish_package` but as an entry function which can be called as a transaction. Because
    /// of current restrictions for txn parameters, the metadata needs to be passed in serialized form.
    public entry fun publish_package_txn(owner: &signer, metadata_serialized: vector<u8>, code: vector<vector<u8>>)
    acquires PackageRegistry {
        publish_package(owner, util::from_bytes<PackageMetadata>(metadata_serialized), code)
    }

    // Helpers
    // -------

    /// Checks whether the given package is upgradable, and returns true if a
    // compatibility check is needed.
    // COMMIT NOTE: we are restoring this for test and reference purposes
    // the vm and framework are allowed to do unchecked upgrades:
    //
    // - system might be dropping a module
    // - system might be changing visibility of functions
    // - system might change policy to stronger or weaker (but this is ignored).
    // - system might intentionally break struct layouts (WARNING: you crazy).
    fun check_upgradability(
        old_pack: &PackageMetadata, new_pack: &PackageMetadata, new_modules:
        &vector<String>) {

        assert!(old_pack.upgrade_policy.policy < upgrade_policy_immutable().policy,
            error::invalid_argument(EUPGRADE_IMMUTABLE));
        assert!(can_change_upgrade_policy_to(old_pack.upgrade_policy, new_pack.upgrade_policy),
            error::invalid_argument(EUPGRADE_WEAKER_POLICY));
        let old_modules = get_module_names(old_pack);
        let i = 0;
        while (i < vector::length(&old_modules)) {
            assert!(
                vector::contains(new_modules, vector::borrow(&old_modules, i)),
                EMODULE_MISSING
            );
            i = i + 1;
        }
    }

    /// Checks whether a new package with given names can co-exist with old package.
    fun check_coexistence(old_pack: &PackageMetadata, new_modules: &vector<String>) {
        // The modules introduced by each package must not overlap with `names`.
        let i = 0;
        while (i < vector::length(&old_pack.modules)) {
            let old_mod = vector::borrow(&old_pack.modules, i);
            let j = 0;
            while (j < vector::length(new_modules)) {
                let name = vector::borrow(new_modules, j);
                assert!(&old_mod.name != name, error::already_exists(EMODULE_NAME_CLASH));
                j = j + 1;
            };
            i = i + 1;
        }
    }

    /// Check that the upgrade policies of all packages are equal or higher quality than this package. Also
    /// compute the list of module dependencies which are allowed by the package metadata. The later
    /// is passed on to the native layer to verify that bytecode dependencies are actually what is pretended here.
    fun check_dependencies(publish_address: address, pack: &PackageMetadata): vector<AllowedDep>
    acquires PackageRegistry {
        let allowed_module_deps = vector::empty();
        let deps = &pack.deps;
        let i = 0;
        let n = vector::length(deps);
        while (i < n) {
            let dep = vector::borrow(deps, i);
            assert!(exists<PackageRegistry>(dep.account), error::not_found(EPACKAGE_DEP_MISSING));
            if (is_policy_exempted_address(dep.account)) {
                // Allow all modules from this address, by using "" as a wildcard in the AllowedDep
                let account = dep.account;
                let module_name = string::utf8(b"");
                vector::push_back(&mut allowed_module_deps, AllowedDep { account, module_name });
                i = i + 1;
                continue
            };
            let registry = borrow_global<PackageRegistry>(dep.account);
            let j = 0;
            let m = vector::length(&registry.packages);
            let found = false;
            while (j < m) {
                let dep_pack = vector::borrow(&registry.packages, j);
                if (dep_pack.name == dep.package_name) {
                    found = true;
                    // Check policy
                    // assert!(
                    //     dep_pack.upgrade_policy.policy >= pack.upgrade_policy.policy,
                    //     error::invalid_argument(EDEP_WEAKER_POLICY)
                    // );
                    if (dep_pack.upgrade_policy == upgrade_policy_arbitrary()) {
                        assert!(
                            dep.account == publish_address,
                            error::invalid_argument(EDEP_ARBITRARY_NOT_SAME_ADDRESS)
                        )
                    };
                    // Add allowed deps
                    let k = 0;
                    let r = vector::length(&dep_pack.modules);
                    while (k < r) {
                        let account = dep.account;
                        let module_name = vector::borrow(&dep_pack.modules, k).name;
                        vector::push_back(&mut allowed_module_deps, AllowedDep { account, module_name });
                        k = k + 1;
                    };
                    break
                };
                j = j + 1;
            };
            assert!(found, error::not_found(EPACKAGE_DEP_MISSING));
            i = i + 1;
        };
        allowed_module_deps
    }

    /// Core addresses which are exempted from the check that their policy matches the referring package. Without
    /// this exemption, it would not be possible to define an immutable package based on the core system, which
    /// requires to be upgradable for maintenance and evolution, and is configured to be `compatible`.
    fun is_policy_exempted_address(addr: address): bool {
        addr == @1 || addr == @2 || addr == @3 || addr == @4 || addr == @5 ||
            addr == @6 || addr == @7 || addr == @8 || addr == @9 || addr == @10
    }

    /// Get the names of the modules in a package.
    fun get_module_names(pack: &PackageMetadata): vector<String> {
        let module_names = vector::empty();
        let i = 0;
        while (i < vector::length(&pack.modules)) {
            vector::push_back(&mut module_names, vector::borrow(&pack.modules, i).name);
            i = i + 1
        };
        module_names
    }

    #[view]
    public fun get_module_names_for_package_index(addr: address, idx: u64): vector<String>
    acquires PackageRegistry {
      let current_packages =
        &borrow_global<PackageRegistry>(addr).packages;
      let pack = vector::borrow(current_packages, idx);
      get_module_names(pack)
    }

    /// Native function to initiate module loading
    native fun request_publish(
        owner: address,
        expected_modules: vector<String>,
        bundle: vector<vector<u8>>,
        policy: u8
    );

    /// A helper type for request_publish_with_allowed_deps
    struct AllowedDep has drop {
        /// Address of the module.
        account: address,
        /// Name of the module. If this is the empty string, then this serves as a wildcard for
        /// all modules from this address. This is used for speeding up dependency checking for packages from
        /// well-known framework addresses, where we can assume that there are no malicious packages.
        module_name: String
    }

    /// Native function to initiate module loading, including a list of allowed dependencies.
    native fun request_publish_with_allowed_deps(
        owner: address,
        expected_modules: vector<String>,
        allowed_deps: vector<AllowedDep>,
        bundle: vector<vector<u8>>,
        policy: u8
    );
}
