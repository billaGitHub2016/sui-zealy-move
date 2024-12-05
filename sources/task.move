/*
任务
*/
module sui_zealy::task {
    use std::string::{String};
    use sui::balance;
    use sui::balance::Balance;
    use sui::clock::Clock;
    use sui::coin::{ Self, Coin };
    use sui::object_table::{Self, ObjectTable};
    use sui::event;
    use sui::random::{Random, new_generator};
    use std::u64::divide_and_round_up;
    use sui_zealy::record::{ Self, Record, update_record, transfer_reward, get_task_result, get_task_ower_address };

    public struct Task<phantom T> has key, store {
        id: UID,
        // 任务名
        name: String,
        // 任务的开始时间
        publish_date: u64,
        // 任务的结束时间
        end_date: u64,
        // 任务状态 0:草稿 1:发布 2:完成
        status: u8,
        // 资金池，用来发放奖励
        pool: Balance<T>,
        // 奖励方式 1: all 2: raffle
        reward_method: u8,
        // 每个申请的奖励金额, reward_method = 1时使用，
        reward_balance: u64,
        // 申请上限
        claim_limit: u64,
        // 申请记录
        records: ObjectTable<ID, Record>,
        // 申请记录的id数组
        records_ids: vector<ID>
    }

    public struct AdminCap has key {
        id: UID,
    }

    public struct TASK_CREATE_EVENT has copy, drop {
        task_id: ID,
        creator_address: address
    }

    public struct TASK_STATUS_EVENT has copy, drop {
        task_id: ID,
        owner_address: address,
        status: u8,
        date: u64
    }

    public struct TASK_REWARD_EVENT has copy, drop {
        task_id: ID,
        owner_address: address,
        reward_address: address,
        reward_coin_value: u64,
        date: u64
    }

    const DraftStatus: u8 = 0;
    const PublishStatus: u8 = 1;
    const CompleteStatus: u8 = 3;

    const RewardAll: u8 = 1;
    const RewardRaffle: u8 = 2;

    const EUnpublishTaskTimeOver: u64 = 11;
    const EUnpublishTaskRecordExists: u64 = 12;
    const ETaskRemoveFailNotReachEndTime: u64 = 13;

    const ERecordNotExist: u64 = 21;
    const ERecordOverDate: u64 = 22;
    const ERecordOverLimit: u64 = 23;

    const Status_Pass: u8 = 2;
    const Status_Reject: u8 = 3;

    fun init(_ctx: &TxContext) {}

    public fun create_task<T>(
        pool: Coin<T>,
        name: String,
        end_date: u64,
        reward_method: u8,
        claim_limit: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let id = object::new(ctx);
        let task_id = id.to_inner();
        let current_date = clock.timestamp_ms();
        let mut task = Task<T> {
            id,
            pool: balance::zero<T>(),
            name,
            publish_date: current_date,
            end_date,
            status: PublishStatus,
            reward_method,
            reward_balance: 0,
            claim_limit,
            records: object_table::new(ctx),
            records_ids: vector::empty<ID>()
        };
        coin::put(&mut task.pool, pool);

        if (task.reward_method == RewardAll) {
            let reward_balance = divide_and_round_up(balance::value(&task.pool), task.claim_limit);
            task.reward_balance = reward_balance;
        };

        event::emit(TASK_CREATE_EVENT {
            task_id,
            creator_address: ctx.sender(),
        });
        transfer::share_object(task);
        let admin_cap = AdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, ctx.sender());
    }

    public fun publish_task<T>(_: &AdminCap, task: &mut Task<T>, clock: &Clock, ctx: &mut TxContext) {
        let current_date = clock.timestamp_ms();
        task.status = PublishStatus;
        task.publish_date = current_date;
        event::emit(TASK_STATUS_EVENT {
            task_id: object::uid_to_inner(&task.id),
            owner_address: ctx.sender(),
            status: PublishStatus,
            date: current_date
        })
    }

    public fun unpublish_task<T>(_: &AdminCap, task: &mut Task<T>, clock: &Clock, ctx: &mut TxContext) {
        let publish_date = task.publish_date;
        let current_date = clock.timestamp_ms();
        assert!(current_date - publish_date < 2 * 60 * 60 * 1000, EUnpublishTaskTimeOver);
        assert!(task.records.length() == 0, EUnpublishTaskRecordExists);
        task.status = DraftStatus;
        event::emit(TASK_STATUS_EVENT {
            task_id: object::uid_to_inner(&task.id),
            owner_address: ctx.sender(),
            status: DraftStatus,
            date: current_date
        })
    }

    public fun add_task_record<T>(
        task: &mut Task<T>,
        content: String,
        file_urls: vector<String>,
        clock: &Clock,
        ctx: &mut TxContext
    ): ID {
        let task_id = task.id.to_inner();
        let new_record = record::new_record(task_id, ctx.sender(), content, file_urls, clock, ctx);
        let new_record_id = new_record.get_id();
        task.records.add(new_record_id, new_record);
        task.records_ids.push_back(new_record_id);
        new_record_id
    }

    fun get_pass_records_count<T>(task: &Task<T>): u64 {
        let records_ids = task.records_ids;
        let mut pass_count = 0;
        let mut i = 0;
        while (i < records_ids.length()) {
            let record = task.records.borrow<ID, Record>(records_ids[i]);
            if (get_task_result(record) == Status_Pass) {
                pass_count = pass_count + 1;
            };
            i = i + 1;
        };
        pass_count
    }

    fun get_pass_records<T>(task: &Task<T>): vector<ID> {
        let records_ids: vector<ID> = task.records_ids;
        let mut i: u64 = 0;
        let mut pass_records = vector::empty<ID>();
        while (i < records_ids.length()) {
            let record = task.records.borrow<ID, Record>(records_ids[i]);
            if (get_task_result(record) == Status_Pass) {
                vector::push_back(&mut pass_records, records_ids[i]);
            };
            i = i + 1;
        };
        pass_records
    }

    public fun handle_claim_task_record<T>(
        task: &mut Task<T>,
        record_id: ID,
        result: u8,
        comment: String,
        _: &AdminCap,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_date = clock.timestamp_ms();
        assert!(object_table::contains<ID, Record>(&task.records, record_id), ERecordNotExist);
        assert!(current_date < task.end_date, ERecordOverDate);

        assert!(get_pass_records_count(task) < task.claim_limit, ERecordOverLimit);
        let record = task.records.borrow_mut<ID, Record>(record_id);
        update_record(record, result, comment, current_date);

        if (task.reward_method == RewardAll) {
            let transfer_record = task.records.borrow<ID, Record>(record_id);

            let left_pool_value = balance::value(&task.pool);
            // let mut reward_coin_balance = task.pool.split(left_pool_value);

            if (left_pool_value > task.reward_balance) {
                let reward_coin_balance = task.pool.split(task.reward_balance); // 检查池子的剩余资金是否足够支付reward_balance，不够就把剩余的资金全部支付
                let reward_coin = coin::from_balance<T>(reward_coin_balance, ctx);
                event::emit(TASK_REWARD_EVENT {
                    task_id: object::uid_to_inner(&task.id),
                    owner_address: ctx.sender(),
                    reward_address: get_task_ower_address(transfer_record),
                    reward_coin_value: coin::value<T>(&reward_coin),
                    date: current_date
                });
                transfer_reward<T>(transfer_record, reward_coin);
            } else {
                let reward_coin_left = coin::from_balance<T>(task.pool.split(left_pool_value), ctx);
                event::emit(TASK_REWARD_EVENT {
                    task_id: object::uid_to_inner(&task.id),
                    owner_address: ctx.sender(),
                    reward_address: get_task_ower_address(transfer_record),
                    reward_coin_value: coin::value<T>(&reward_coin_left),
                    date: current_date
                });
                transfer_reward<T>(transfer_record, reward_coin_left);
            };
        };
    }

    public fun handle_task_raffle<T>(
        _: &AdminCap,
        task: &mut Task<T>,
        r: &Random,
        clock: &Clock,
        ctx: &mut TxContext) {
        let current_date = clock.timestamp_ms();
        assert!(current_date < task.end_date, ERecordOverDate);

        let pass_records: vector<sui::object::ID> = get_pass_records<T>(task);
        let mut generator = new_generator(r, ctx);
        let v: u64 = generator.generate_u64_in_range(0, pass_records.length() - 1);
        let lucky_record_id: ID = pass_records[v];
        let lucky_record: &Record = task.records.borrow(lucky_record_id);
        let pool_balance = task.pool.value();
        let reward_coin_balance = task.pool.split(pool_balance);

        event::emit(TASK_REWARD_EVENT {
            task_id: object::uid_to_inner(&task.id),
            owner_address: ctx.sender(),
            reward_address: get_task_ower_address(lucky_record),
            reward_coin_value: balance::value<T>(&reward_coin_balance),
            date: current_date
        });

        let reward_coin = coin::from_balance<T>(reward_coin_balance, ctx);
        transfer_reward<T>(lucky_record, reward_coin);


    }

    public fun remove_all_task_records<T>(task: &mut Task<T>, _: &AdminCap, _clock: &Clock, _ctx: &mut TxContext) {
        let mut i = 0;
        while (i < task.records_ids.length()) {
            task.records.remove(task.records_ids[i]).delete_record();
            i = i + 1
        };
        i = task.records_ids.length();
        while (i > 0) {
            task.records_ids.remove(i - 1);
            i = task.records_ids.length();
        };
        // task.records.destroy_empty();
        // task.records_ids.destroy_empty();
    }

    #[allow(lint(self_transfer))]
    public fun withdraw_task<T>(task: &mut Task<T>, _: &AdminCap, _clock: &Clock, ctx: &mut TxContext) {
        let pool_balance = task.pool.value();
        let withdraw_coin_balance = task.pool.split(pool_balance);
        let withdraw_coin = coin::from_balance(withdraw_coin_balance, ctx);
        transfer::public_transfer(withdraw_coin, ctx.sender());
    }

    public fun remove_task<T>(task: Task<T>, _: &AdminCap, clock: &Clock, _ctx: &mut TxContext) {
        let Task { id, name: _, publish_date: _, end_date, status: _, pool, reward_method: _, claim_limit: _, records, records_ids, reward_balance: _ } = task;
        let current_date = clock.timestamp_ms();
        assert!(current_date > end_date, ETaskRemoveFailNotReachEndTime);
        assert!(object_table::is_empty<ID, Record>(&records), 1);
        object_table::destroy_empty<ID, Record>(records);
        assert!(vector::is_empty<ID>(&records_ids), 2);
        vector::destroy_empty<ID>(records_ids);

        pool.destroy_zero();
        object::delete(id);
    }

    #[test_only] use sui::object::ID;
    #[test_only] use sui::sui::SUI;
    #[test_only] use sui::test_scenario as ts;
    #[test_only] use std::string::{ utf8 };
    #[test_only] use sui::clock;
    #[test_only]
    use sui::test_scenario::Scenario;

    #[test_only] const OnedayMs: u64 = 86400000; // 1天的毫秒数

    #[test_only]
    public fun name<T>(task: &Task<T>): String {
        task.name
    }

    #[test_only]
    public fun pool<T>(task: &Task<T>): u64 {
        task.pool.value()
    }

    #[test_only]
    public fun destory_admin_cap(cap: AdminCap) {
        let AdminCap { id } = cap;
        object::delete(id);
    }

    #[test_only]
    fun mint(addr: address, amount: u64, scenario: &mut ts::Scenario) {
        transfer::public_transfer(coin::mint_for_testing<SUI>(amount, scenario.ctx()), addr);
        scenario.next_tx(addr);
    }

    #[test]
    fun test_all_task_complete() {
        let task_owner = @0xA;
        let user1 = @0xB;
        let user2 = @0xC;
        let mut ts = ts::begin(task_owner);
        let mut clock = clock::create_for_testing(ts.ctx());

        let (task_id, admin_cap): (ID, AdminCap) = {
            mint(task_owner, 1000, &mut ts);
            let name: String = utf8(b"拼多多砍一刀");
            let publish_date: u64 = clock.timestamp_ms();
            let end_date: u64 = publish_date + OnedayMs;
            ts.next_tx(task_owner);
            let coin: Coin<SUI> = ts.take_from_sender();
            create_task<SUI>(coin, name, publish_date, end_date, 1, 2, ts.ctx());
            ts.next_tx(task_owner);
            let task = ts.take_shared<Task<SUI>>();
            let task_id = object::id(&task);
            let admin_cap: AdminCap = ts.take_from_sender<AdminCap>();
            assert!(task.name<SUI>() == name, 1);
            assert!(task.pool<SUI>() == 1000, 2);
            ts::return_shared(task);

            (task_id, admin_cap)
        };

        let record_1_id = {
            ts.next_tx(user1);
            let file_urls = vector<String>[utf8(b"https://avatars.githubusercontent.com/u/9780825?v=4")];
            let mut task = ts.take_shared_by_id<Task<SUI>>(task_id);
            // let record_id = add_task_record<SUI>(task, utf8(b"砍1刀"), file_urls, &clock, ts.ctx());
            let record_id = task.add_task_record<SUI>(utf8(b"砍1刀"), file_urls, &clock, ts.ctx());
            assert!(task.records.length() == 1, 3);
            assert!(task.records_ids.length() == 1, 4);
            ts::return_shared(task);
            record_id
        };

        let record_2_id = {
            ts.next_tx(user2);
            let mut task = ts.take_shared_by_id<Task<SUI>>(task_id);
            let file_urls = vector<String>[utf8(b"https://github.githubassets.com/assets/pull-shark-default-498c279a747d.png")];
            let record_id = task.add_task_record(utf8(b"砍2刀"), file_urls, &clock, ts.ctx());
            assert!(task.records.length() == 2, 5);
            assert!(task.records_ids.length() == 2, 6);
            ts::return_shared(task);
            record_id
        };

        {
            ts.next_tx(task_owner);
            let mut task = ts.take_shared_by_id<Task<SUI>>(task_id);
            task.handle_claim_task_record<SUI>(record_1_id, Status_Pass, utf8(b"nice job"), &admin_cap, &clock, ts.ctx());
            ts::return_shared(task);
        };

        {
            ts.next_tx(task_owner);
            let mut task = ts.take_shared_by_id<Task<SUI>>(task_id);
            task.handle_claim_task_record<SUI>(record_2_id, Status_Pass, utf8(b"nice job, too"), &admin_cap, &clock, ts.ctx());
            ts::return_shared(task);
        };

        {
            ts.next_tx(user1);
            let coin: Coin<SUI> = ts.take_from_sender();
            assert!(coin.value() == 500, 7);
            coin.burn_for_testing();
        };

        {
            ts.next_tx(user2);
            let coin: Coin<SUI> = ts.take_from_sender();
            assert!(coin.value() == 500, 8);
            coin.burn_for_testing();
        };

        {
            ts.next_tx(task_owner);
            let mut task = ts.take_shared_by_id<Task<SUI>>(task_id);
            clock.set_for_testing(OnedayMs + 1);
            // remove_all_task_records<SUI>(&admin_cap, task, &clock, ts.ctx());
            task.remove_all_task_records<SUI>(&admin_cap, &clock, ts.ctx());
            // withdraw_task<SUI>(&admin_cap, task, &clock, ts.ctx());
            task.withdraw_task<SUI>(&admin_cap, &clock, ts.ctx());
            ts::return_shared(task);

            ts.next_tx(task_owner);
            let withdraw_coin: Coin<SUI> = ts.take_from_sender();
            assert!(withdraw_coin.value() == 0, 9);

            withdraw_coin.burn_for_testing();
        };

        {
            ts.next_tx(task_owner);
            let task = ts.take_shared_by_id<Task<SUI>>(task_id);
            task.remove_task<SUI>(&admin_cap, &clock, ts.ctx());
        };

        destory_admin_cap(admin_cap);
        clock.destroy_for_testing();
        ts.end();
    }
}
