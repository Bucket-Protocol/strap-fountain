#[test_only]
module strap_fountain::test_stake {
    
    use std::option;
    use sui::sui::SUI;
    use sui::transfer;
    use sui::object;
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::balance;
    use sui::coin;
    use bucket_oracle::bucket_oracle::BucketOracle;
    use bucket_protocol::test_utils as btu;
    use bucket_protocol::buck::{Self, BucketProtocol};
    use bucket_protocol::strap;
    use strap_fountain::fountain::{Self, Fountain, StakeProof, AdminCap};

    public fun dev(): address { @0xde1 }

    public fun start_time(): u64 { 1690466779049 }

    public fun setup_for_testing(
        oracle_price: u64,
        flow_amount: u64,
        flow_interval: u64,
    ): Scenario {
        let scenario_val = btu::setup_empty_with_interest(oracle_price);
        let scenario = &mut scenario_val;

        ts::next_tx(scenario, dev());
        {
            let cap = fountain::create<SUI, SUI>(
                flow_amount,
                flow_interval,
                start_time(),
                ts::ctx(scenario),
            );
            transfer::public_transfer(cap, dev());
        };

        scenario_val
    }

    #[test]
    fun test_stake() {
        let oracle_price = 2_000;
        let flow_amount = 10_000_000_000;
        let flow_interval = 86400_000;
        let scenario_val = setup_for_testing(oracle_price, flow_amount, flow_interval);
        let scenario = &mut scenario_val;
        
        // create straps -> borrow with the straps -> stake the straps
        let user = @0x123;
        let input_amount_1 = 10_000_000_000;
        let borrow_amount_1 = 10_000_000_000;
        let input_amount_2 = 100_000_000_000;
        let borrow_amount_2 = 40_000_000_000;
        ts::next_tx(scenario, user);
        let (proof_1_id, proof_2_id) = {
            let protocol = ts::take_shared<BucketProtocol>(scenario);
            let oracle = ts::take_shared<BucketOracle>(scenario);
            let clock = ts::take_shared<Clock>(scenario);
            let fountain = ts::take_shared<Fountain<SUI, SUI>>(scenario);
            let ctx = ts::ctx(scenario);

            let strap_1 = strap::new<SUI>(ctx);
            let input = balance::create_for_testing<SUI>(input_amount_1);
            let output = buck::borrow_with_strap(
                &mut protocol,
                &oracle,
                &strap_1,
                &clock,
                input,
                borrow_amount_1,
                option::none(),
                ctx,
            );
            balance::destroy_for_testing(output);
            let proof_1 = fountain::stake(
                &mut fountain, &protocol, &clock, strap_1, ctx,
            );
            let proof_1_id = object::id(&proof_1);
            transfer::public_transfer(proof_1, user);

            let strap_2 = strap::new<SUI>(ctx);
            let input = balance::create_for_testing<SUI>(input_amount_2);
            let output = buck::borrow_with_strap(
                &mut protocol,
                &oracle,
                &strap_2,
                &clock,
                input,
                borrow_amount_2,
                option::none(),
                ctx,
            );
            balance::destroy_for_testing(output);
            let proof_2 = fountain::stake(
                &mut fountain, &protocol, &clock, strap_2, ctx,
            );
            let proof_2_id = object::id(&proof_2);
            transfer::public_transfer(proof_2, user);

            // std::debug::print(&fountain);

            ts::return_shared(protocol);
            ts::return_shared(oracle);
            ts::return_shared(clock);
            ts::return_shared(fountain);
            (proof_1_id, proof_2_id)
        };

        ts::next_tx(scenario, dev());
        {
            let fountain = ts::take_shared<Fountain<SUI, SUI>>(scenario);
            let clock = ts::take_shared<Clock>(scenario);
            let ctx = ts::ctx(scenario);

            let fund = coin::mint_for_testing<SUI>(flow_amount * 10, ctx);
            fountain::supply(&mut fountain, &clock, fund);
            clock::set_for_testing(&mut clock, start_time() + 86400_000);

            ts::return_shared(fountain);
            ts::return_shared(clock);
        };

        ts::next_tx(scenario, user);
        {
            let fountain = ts::take_shared<Fountain<SUI, SUI>>(scenario);
            let protocol = ts::take_shared<BucketProtocol>(scenario);
            let clock = ts::take_shared<Clock>(scenario);
            let proof_1 = ts::take_from_sender_by_id<StakeProof<SUI, SUI>>(
                scenario, proof_1_id,
            );
            let proof_2 = ts::take_from_sender_by_id<StakeProof<SUI, SUI>>(
                scenario, proof_2_id,
            );

            let reward = fountain::claim(
                &mut fountain,
                &protocol,
                &clock,
                &mut proof_1,
                ts::ctx(scenario),
            );
            // std::debug::print(&reward);
            assert!(coin::value(&reward) == flow_amount/5 - 1, 0);
            coin::burn_for_testing(reward);
            ts::return_to_sender(scenario, proof_1);

            let (strap_2, reward) = fountain::unstake(
                &mut fountain,
                &protocol,
                &clock,
                proof_2,
                ts::ctx(scenario),
            );
            // std::debug::print(&reward);
            assert!(coin::value(&reward) == flow_amount*4/5 - 1, 0);
            coin::burn_for_testing(reward);
            transfer::public_transfer(strap_2, user);

            ts::return_shared(fountain);
            ts::return_shared(protocol);
            ts::return_shared(clock);
        };

        ts::next_tx(scenario, dev());
        {
            let clock = ts::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, 86400_000);
            ts::return_shared(clock);
        };

        ts::next_tx(scenario, user);
        {
            let fountain = ts::take_shared<Fountain<SUI, SUI>>(scenario);
            let protocol = ts::take_shared<BucketProtocol>(scenario);
            let clock = ts::take_shared<Clock>(scenario);
            let proof_1 = ts::take_from_sender_by_id<StakeProof<SUI, SUI>>(
                scenario, proof_1_id,
            );

            let reward = fountain::claim(
                &mut fountain,
                &protocol,
                &clock,
                &mut proof_1,
                ts::ctx(scenario),
            );
            // std::debug::print(&reward);
            assert!(coin::value(&reward) == flow_amount - 1, 0);
            coin::burn_for_testing(reward);
            ts::return_to_sender(scenario, proof_1);

            ts::return_shared(fountain);
            ts::return_shared(protocol);
            ts::return_shared(clock);
        };

        ts::next_tx(scenario, dev());
        {
            let fountain = ts::take_shared<Fountain<SUI, SUI>>(scenario);
            let clock = ts::take_shared<Clock>(scenario);
            let admin_cap = ts::take_from_sender<AdminCap>(scenario);

            fountain::update_flow_rate(
                &admin_cap,
                &clock,
                &mut fountain,
                flow_amount / 2,
                flow_interval,
            );
            clock::increment_for_testing(&mut clock, 86400_000);

            ts::return_shared(fountain);
            ts::return_shared(clock);
            ts::return_to_sender(scenario, admin_cap);
        };

        ts::next_tx(scenario, user);
        {
            let fountain = ts::take_shared<Fountain<SUI, SUI>>(scenario);
            let protocol = ts::take_shared<BucketProtocol>(scenario);
            let clock = ts::take_shared<Clock>(scenario);
            let proof_1 = ts::take_from_sender_by_id<StakeProof<SUI, SUI>>(
                scenario, proof_1_id,
            );

            let reward = fountain::claim(
                &mut fountain,
                &protocol,
                &clock,
                &mut proof_1,
                ts::ctx(scenario),
            );
            // std::debug::print(&reward);
            assert!(coin::value(&reward) == flow_amount/2 - 1, 0);
            coin::burn_for_testing(reward);
            ts::return_to_sender(scenario, proof_1);

            ts::return_shared(fountain);
            ts::return_shared(protocol);
            ts::return_shared(clock);
        };

        ts::end(scenario_val);
    }
}