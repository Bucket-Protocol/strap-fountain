module strap_fountain::fountain {

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::tx_context::TxContext;
    use sui::object::{Self, ID, UID};
    use sui::clock::{Self, Clock};
    // use sui::event;
    use sui::table::{Self, Table};
    use sui::transfer;
    use bucket_protocol::strap::{Self, BottleStrap};
    use bucket_protocol::buck::{Self, BucketProtocol};
    use bucket_protocol::bucket;
    use bucket_protocol::bottle;

    // --------------- Constant ---------------

    const DISTRIBUTION_PRECISION: u128 = 0x10000000000000000;

    // --------------- Errors ---------------

    const EDividedByZero: u64 = 0;
    const EInvalidProof: u64 = 1;
    const EInvalidAdminCap: u64 = 2;
    const EInvalidStrapToStake: u64 = 3;

    // --------------- Objects ---------------

    struct AdminCap has key, store {
        id: UID,
        fountain_id: ID,
    }

    struct Fountain<phantom T, phantom R> has key {
        id: UID,
        source: Balance<R>,
        flow_amount: u64,
        flow_interval: u64,
        pool: Balance<R>,
        total_debt_amount: u64,
        strap_table: Table<ID, BottleStrap<T>>,
        cumulative_unit: u128,
        latest_release_time: u64,
    }

    struct StakeProof<phantom T, phantom R> has key, store {
        id: UID,
        fountain_id: ID,
        strap_address: address,
        start_unit: u128,
    }

    // --------------- Public Functions ---------------

    public fun create<T, R>(
        flow_amount: u64,
        flow_interval: u64,
        start_time: u64,
        ctx: &mut TxContext,
    ) {
        let fountain = Fountain<T, R> {
            id: object::new(ctx),
            source: balance::zero(),
            flow_amount,
            flow_interval,
            pool: balance::zero(),
            total_debt_amount: 0,
            strap_table: table::new(ctx),
            cumulative_unit: 0,
            latest_release_time: start_time,
        };
        transfer::share_object(fountain);
    }

    public fun supply<T, R>(
        fountain: &mut Fountain<T, R>,
        clock: &Clock,
        resource: Coin<R>,
    ) {
        source_to_pool(fountain, clock);
        coin::put(&mut fountain.source, resource);
    }

    public fun stake<T, R>(
        fountain: &mut Fountain<T, R>,
        protocol: &BucketProtocol,
        clock: &Clock,
        strap: BottleStrap<T>,
        ctx: &mut TxContext,
    ): StakeProof<T, R> {
        assert_valid_strap_to_stake<T>(protocol, &strap);
        source_to_pool(fountain, clock);
        let strap_addr = strap::get_address(&strap);
        let debt_amount = raw_debt_by_debtor<T>(protocol, strap_addr);
        let id = object::new(ctx);
        let proof_id = object::uid_to_inner(&id);
        let strap_address = object::id_address(&strap);
        table::add(&mut fountain.strap_table, proof_id, strap);
        fountain.total_debt_amount = fountain.total_debt_amount + debt_amount;
        StakeProof<T, R> {
            id,
            fountain_id: object::id(fountain),
            strap_address,
            start_unit: fountain.cumulative_unit,
        }
    }

    public fun claim<T, R>(
        fountain: &mut Fountain<T, R>,
        protocol: &BucketProtocol,
        clock: &Clock,
        proof: &mut StakeProof<T, R>,
        ctx: &mut TxContext,
    ): Coin<R> {
        assert_valid_proof(fountain, proof);
        source_to_pool(fountain, clock);
        let current_time = clock::timestamp_ms(clock);
        let reward_amount = get_reward_amount(fountain, protocol, proof, current_time);
        proof.start_unit = cumulative_unit(fountain);
        coin::take(&mut fountain.pool, reward_amount, ctx)
    }

    public fun unstake<T, R>(
        fountain: &mut Fountain<T, R>,
        protocol: &BucketProtocol,
        clock: &Clock,
        proof: StakeProof<T, R>,
        ctx: &mut TxContext,
    ): (BottleStrap<T>, Coin<R>) {
        assert_valid_proof(fountain, &proof);
        source_to_pool(fountain, clock);
        let reward = claim(fountain, protocol, clock, &mut proof, ctx);
        let debt_amount = raw_debt_by_proof<T, R>(protocol, &proof);
        let StakeProof {
            id,
            fountain_id: _,
            strap_address: _,
            start_unit: _,
        } = proof;
        let proof_id = object::uid_to_inner(&id);
        object::delete(id);
        fountain.total_debt_amount = total_debt_amount(fountain) - debt_amount;
        let strap = table::remove(&mut fountain.strap_table, proof_id);
        (strap, reward)
    }

    // public fun liquidate<T, R>(
    //     fountain: 
    // )

    // --------------- Admin Functions ---------------

    public fun update_flow_rate<T, R>(
        cap: &AdminCap,
        clock: &Clock,
        fountain: &mut Fountain<T, R>,
        flow_amount: u64,
        flow_interval: u64
    ) {
        assert_valid_admin_cap(fountain, cap);
        source_to_pool(fountain, clock);
        fountain.flow_amount = flow_amount;
        fountain.flow_interval = flow_interval;
    }

    public fun withdraw_from_source_to<T, R>(
        cap: &AdminCap,
        fountain: &mut Fountain<T, R>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert_valid_admin_cap(fountain, cap);
        let withdrawal = coin::take(&mut fountain.source, amount, ctx);
        transfer::public_transfer(withdrawal, recipient);
    }

    // --------------- Fountain Getter Functions ---------------

    public fun source_balance<T, R>(fountain: &Fountain<T, R>): u64 {
        balance::value(&fountain.source)
    }

    public fun flow_rate<T, R>(fountain: &Fountain<T, R>): (u64, u64) {
        (fountain.flow_amount, fountain.flow_interval)
    }

    public fun pool_balance<T, R>(fountain: &Fountain<T, R>): u64 {
        balance::value(&fountain.pool)
    }

    public fun total_debt_amount<T, R>(fountain: &Fountain<T, R>): u64 {
        fountain.total_debt_amount
    }

    public fun cumulative_unit<T, R>(fountain: &Fountain<T, R>): u128 {
        fountain.cumulative_unit
    }

    public fun latest_release_time<T, R>(fountain: &Fountain<T, R>): u64 {
        fountain.latest_release_time
    }

   // --------------- StakeProof Getter Functions ---------------

    public fun fountain_id<T, R>(proof: &StakeProof<T, R>): ID {
        proof.fountain_id
    }

    public fun strap_address<T, R>(proof: &StakeProof<T, R>): address {
        proof.strap_address
    }

    public fun start_unit<T, R>(proof: &StakeProof<T, R>): u128 {
        proof.start_unit
    }

    // --------------- Computational Functions ---------------

    public fun get_reward_amount<T, R>(
        fountain: &Fountain<T, R>,
        protocol: &BucketProtocol,
        proof: &StakeProof<T, R>,
        current_time: u64,
    ): u64 {
        let virtual_released_amount = get_virtual_released_amount(fountain, current_time);
        let virtual_cumulative_unit = fountain.cumulative_unit +
            (virtual_released_amount as u128) *
            DISTRIBUTION_PRECISION /
            (total_debt_amount(fountain) as u128);
        let debt_amount = raw_debt_by_proof<T, R>(protocol, proof);
        mul_and_div_u128(
            debt_amount,
            virtual_cumulative_unit - start_unit(proof),
            DISTRIBUTION_PRECISION
        )
    }

    public fun get_virtual_released_amount<T, R>(
        fountain: &Fountain<T, R>,
        current_time: u64,
    ): u64 {
        let latest_release_time = latest_release_time(fountain);
        if (current_time > latest_release_time) {
            let interval = current_time - latest_release_time;
            let (flow_amount, flow_interval) = flow_rate(fountain);
            let released_amount = mul_and_div(flow_amount, interval, flow_interval);
            let source_balance = source_balance(fountain);
            if (released_amount > source_balance) {
                released_amount = source_balance;
            };
            released_amount
        } else {
            0
        }
    }

    fun raw_debt_by_debtor<T>(
        protocol: &BucketProtocol,
        debtor: address,
    ): u64 {
        let bucket = buck::borrow_bucket<T>(protocol);
        let bottle_table = bucket::borrow_bottle_table(bucket);
        let (_, debt_amount) = bottle::get_bottle_raw_info_by_debator(bottle_table, debtor);
        debt_amount
    }

    fun raw_debt_by_proof<T, R>(
        protocol: &BucketProtocol,
        proof: &StakeProof<T, R>,
    ): u64 {
        let strap_address = strap_address(proof);
        raw_debt_by_debtor<T>(protocol, strap_address)
    }

    // fun bottle_exists_by_proof<T, R>(
    //     protocol: &BucketProtocol,
    //     proof: &StakeProof<T, R>,
    // ): bool {
    //     let strap_address = strap_address(proof);
    //     let bucket = buck::borrow_bucket<T>(protocol);
    //     bucket::bottle_exists(bucket, strap_address)
    // }

    fun release_resource<T, R>(fountain: &mut Fountain<T, R>, clock: &Clock): Balance<R> {
        let current_time = clock::timestamp_ms(clock);
        let latest_release_time = latest_release_time(fountain);
        if (current_time > latest_release_time) {
            let interval = current_time - latest_release_time;
            let (flow_amount, flow_interval) = flow_rate(fountain);
            let released_amount = mul_and_div(flow_amount, interval, flow_interval);
            let source_balance = source_balance(fountain);
            if (released_amount > source_balance) {
                released_amount = source_balance;
            };
            fountain.latest_release_time = current_time;
            balance::split(&mut fountain.source, released_amount)
        } else {
            balance::zero()
        }
    }

    fun collect_resource<T, R>(fountain: &mut Fountain<T, R>, resource: Balance<R>) {
        let resource_amount = balance::value(&resource);
        if (resource_amount > 0) {
            balance::join(&mut fountain.pool, resource);
            let unit_increased = mul_and_div_u128(
                resource_amount,
                DISTRIBUTION_PRECISION,
                (total_debt_amount(fountain) as u128),
            );
            fountain.cumulative_unit =
                cumulative_unit(fountain) +
                (unit_increased as u128);
        } else {
            balance::destroy_zero(resource);
        };
    }

    fun source_to_pool<T, R>(fountain: &mut Fountain<T, R>, clock: &Clock) {
        if (source_balance(fountain) > 0) {
            let resource = release_resource(fountain, clock);
            collect_resource(fountain, resource);
        } else {
            let current_time = clock::timestamp_ms(clock);
            if (current_time > latest_release_time(fountain)) {
                fountain.latest_release_time = current_time;
            };
        }
    }

    fun mul_and_div(x: u64, n: u64, m: u64): u64 {
        assert!(m > 0, EDividedByZero);
        ((
            (x as u128) * (n as u128) / (m as u128)
        ) as u64)
    }

    fun mul_and_div_u128(x: u64, n: u128, m: u128): u64 {
        assert!(m > 0, EDividedByZero);
        ((
            (x as u128) * n / m
        ) as u64)
    }

    // --------------- Asset Functions ---------------

    fun assert_valid_proof<T, R>(
        fountain: &Fountain<T, R>,
        proof: &StakeProof<T, R>,
    ) {
        assert!(object::id(fountain) == fountain_id(proof), EInvalidProof);
    }

    fun assert_valid_admin_cap<T, R>(
        fountain: &Fountain<T, R>,
        cap: &AdminCap,
    ) {
        assert!(object::id(fountain) == cap.fountain_id, EInvalidAdminCap);
    }

    fun assert_valid_strap_to_stake<T>(
        protocol: &BucketProtocol,
        strap: &BottleStrap<T>,
    ) {
        let strap_address = strap::get_address(strap);
        let bucket = buck::borrow_bucket<T>(protocol);
        assert!(bucket::bottle_exists(bucket, strap_address), EInvalidStrapToStake);
    }
}