// Simple example to set/get string on chain
// Taken/modified from diem-core:
// diem-move/move-examples/hello_blockchain/sources/hello_blockchain.move
#[test_only]
module ol_framework::demo {
    use std::error;
    use std::signer;
    use std::string;
    use diem_framework::account;
    use diem_framework::event;

    use diem_std::debug::print;

//:!:>resource
    struct MessageHolder has key {
        message: string::String,
        message_change_events: event::EventHandle<MessageChangeEvent>,
    }
//<:!:resource

    struct MessageChangeEvent has drop, store {
        from_message: string::String,
        to_message: string::String,
    }

    /// There is no message present
    const ENO_MESSAGE: u64 = 0;

    #[view]
    public fun get_message(addr: address): string::String acquires MessageHolder {
        assert!(exists<MessageHolder>(addr), error::not_found(ENO_MESSAGE));
        *&borrow_global<MessageHolder>(addr).message
    }

    fun print_this(account: &signer) {
      print(&11111111);
      print(&signer::address_of(account));
    }

    fun set_message(account: &signer, message: string::String)
    acquires MessageHolder {
        let account_addr = signer::address_of(account);
        if (!exists<MessageHolder>(account_addr)) {
            move_to(account, MessageHolder {
                message,
                message_change_events: account::new_event_handle<MessageChangeEvent>(account),
            })
        } else {
            let old_message_holder = borrow_global_mut<MessageHolder>(account_addr);
            let from_message = *&old_message_holder.message;
            event::emit_event(&mut old_message_holder.message_change_events, MessageChangeEvent {
                from_message,
                to_message: copy message,
            });
            old_message_holder.message = message;
        }
    }

    #[test(account = @0x1)]
    fun sender_can_set_message(account: signer) acquires MessageHolder {
        let addr = signer::address_of(&account);
        diem_framework::account::create_account_for_test(addr);
        set_message(&account,  string::utf8(b"Hello, Blockchain"));

        assert!(
          get_message(addr) == string::utf8(b"Hello, Blockchain"),
          ENO_MESSAGE
        );
    }
}
