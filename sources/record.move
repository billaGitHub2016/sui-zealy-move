/// claim记录
module sui_zealy::record {
    use std::string::{String, utf8};
    use sui::clock::Clock;
    use sui::coin::Coin;

    public struct Record has key, store {
        id: UID,
        // 关联任务id
        task_id: ID,
        // 提交人地址
        ower_address: address,
        // 说明文字
        content: String,
        // 上传文件url数组
        file_urls: vector<String>,
        // 提交时间
        date: u64,
        // 审核结果 1:审核中 2:通过 3:拒绝
        result: u8,
        // 审核时间
        process_date: u64,
        // 反馈
        comment: String,
    }

    const Status_Reviewing: u8 = 1;
    const Status_Pass: u8 = 2;
    const Status_Reject: u8 = 3;

    /// 新增一个提交记录
    public(package) fun new_record(
        task_id: ID,
        ower_address: address,
        content: String,
        file_urls: vector<String>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Record {
        let new_record = Record {
            id: object::new(ctx),
            task_id,
            ower_address,
            content,
            file_urls,
            date: clock.timestamp_ms(),
            result: 0,
            process_date: 0,
            comment: utf8(b"")
        };
        new_record
    }

    public(package) fun delete_record(record: Record) {
        let Record {
            id, task_id: _, ower_address: _, content: _, file_urls: _, date: _, result: _, process_date: _, comment: _
        } = record;
        object::delete(id);
    }

    public(package) fun update_record(record: &mut Record, result: u8, comment: String, process_date: u64) {
        record.process_date = process_date;
        record.comment = comment;
        record.result = result;
    }

    public(package) fun transfer_reward<T>(record: &Record, reward_coin: Coin<T>) {
        transfer::public_transfer(reward_coin, record.ower_address);
    }

    public(package) fun get_task_result(record: &Record): u8 {
        record.result
    }

    public(package) fun get_id(rec: &Record): ID {
        rec.id.to_inner()
    }

    public(package) fun get_task_ower_address(rec: &Record): address {
        rec.ower_address
    }
}