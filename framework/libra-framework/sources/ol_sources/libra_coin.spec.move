spec ol_framework::libra_coin {
    spec module {
        pragma verify = true;
        pragma aborts_if_is_strict;
    }

    spec initialize {
        pragma aborts_if_is_partial;
        let addr = signer::address_of(diem_framework);
        ensures exists<MintCapStore>(addr);
        ensures exists<coin::CoinInfo<LibraCoin>>(addr);
    }

    // spec destroy_mint_cap {
    //     let addr = signer::address_of(diem_framework);
    //     aborts_if addr != @diem_framework;
    //     aborts_if !exists<MintCapStore>(@diem_framework);
    // }

    // Test function,not needed verify.
    spec configure_accounts_for_test {
        pragma verify = false;
    }

    // // Only callable in tests and testnets.not needed verify.
    // spec mint {
    //     pragma verify = false;
    // }

    // Only callable in tests and testnets.not needed verify.
    spec delegate_mint_capability {
        pragma verify = false;
    }

    // Only callable in tests and testnets.not needed verify.
    spec claim_mint_capability(account: &signer) {
        pragma verify = false;
    }

    spec find_delegation(addr: address): Option<u64> {
        aborts_if !exists<Delegations>(@core_resources);
    }
}
