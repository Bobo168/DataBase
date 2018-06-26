
//  Copyright © 2018年 boboMa. All rights reserved.
//

import Foundation
import FMDB

///最大的数据库缓存时间，以 S 为单位 '-5'表示往前推5天
private let maxDBCacheTime:TimeInterval = -5 * 24 * 60 * 60

// MARK: - SQLite管理器
/**
 1.数据库本质上是保存在沙盒中的一个文件，首先需要创建并且打开数据库
   FMDB - 队列
 2.创建数据表
 3.增删改查
 */
class CZSQLiteManager {
    ///单例，全局数据库工具访问点
    static let shared = CZSQLiteManager()
    ///数据库队列
    let queue:FMDatabaseQueue
    
    ///构造函数
    private init(){
       //数据库的全路径 - path
        let dbName = "status.db"
        var  path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        path = (path as NSString).appendingPathComponent(dbName)
        
        print("数据库的路径" + path)
        //创建数据库队列,同时‘创建或打开’数据库(这时候数据库是空的什么都没有)
        queue = FMDatabaseQueue(path: path)
        // 打开数据库
        createTable()
       //注册通知 - 监听应用程序进入后台
        //模仿 SDWebImage
        NotificationCenter.default.addObserver(self, selector: #selector(clearDBCache), name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
    }
    deinit {
        //注销通知
        NotificationCenter.default.removeObserver(self)
    }
    

    
}

// MARK: - 数据操作
extension CZSQLiteManager{
    
// MARK: -*********************************从数据库加载数据数组*********************************
    /// - Parameters:
    ///   - userId: 当前登录的用户账号
    ///   - since_id: 返回ID比since_id大的数据
    ///   - max_id: 返回ID小于max_id的数据
    /// - Returns: 数据的字典的数组，将数据库中status字段对应的二进制数据反序列化，生成字典
    func loadStatus(userId:String,since_id:Int64 = 0,max_id:Int64 = 0) -> [[String:AnyObject]] {
        //1.准备SQL
        var  sql = "SELECT statusId,userId,status FROM T_Status \n"
        
        sql += "WHERE userId = \(userId) \n"
        // 上拉 / 下拉 都是针对同一个ID进行判断
        if since_id > 0{
            //下拉
            sql += "AND statusId > \(since_id) \n"
        }else if max_id > 0{
            //上拉
            sql += "AND statusId < \(max_id) \n"
        }
        sql += "ORDER BY statusId DESC LIMIT 20;"
      //拼接 SQL 结束后，一定要测试
        
        print(sql)
        //2.执行SQL
        let array = execRecordSet(sql: sql)
        //3.遍历数组，将数组中的 status 反序列化 -> 字典的数组
        var result = [[String:AnyObject]]()
        for dict in array {
            //反序列化
            guard let jsonData = dict["status"] as? Data,
                let json = try? JSONSerialization.jsonObject(with: jsonData, options: []) as?[String:AnyObject]else{
                    continue
            }
            //追加到数组
            result.append(json ?? [:])
        }
        
        
        return result
    }
    
    
    
// MARK: -*********************************新增或者修改**************************************
    /**
     从网络加载结束后，返回的是数据的‘字典数组’，每一个字典对应一个完整的数据记录
      - 完整的数据记录中，包含数据的代号
      - 数据记录中，没有当前登录的用户代号
     */
  
    /// 新增或者修改数据数据，数据数据在刷新的时候，可能会出现重叠
    ///   - userId: 当前登录用户的ID
    ///   - array: 从网络获取的‘字典数组’
    func updateStatus(userId:String,array:[[String:AnyObject]]){
       
        //1.准备SQL
        /**
         statusId: 要保存的数据代号
         userId:   当前登录用户的 ID
         status:  完整数据字典的json 二进制数据
         */
        let sql = "INSERT OR REPLACE INTO T_Status(statusId,userId,status) VALUES(?,?,?);"
        
        //2.执行SQL
        
        queue.inTransaction { (db, rollback) in
            
            //遍历数组，逐条插入数据数据
            for dict in array{
                //从字典获取数据代号 / 将字典序列化成二进制数据
                guard let statusId = dict["idstr"] as? String,
                      let jsonData = try?  JSONSerialization.data(withJSONObject: dict, options: []) else{
                        continue
                }
                
                //执行 SQL
                if db.executeUpdate(sql, withArgumentsIn: [statusId,userId,jsonData]) == false{
                    //需要回滚 *rollback = YES;
                    //Swift 1.x & 2.x => rollback.memory = true
                    //Swift3.0的写法
                    rollback.pointee = true
                    
                    break
                }
            }
        }
    }
// MARK: -*********************************清理数据缓存*********************************
    ///清理数据缓存
    ///注意细节：
    ///SQLite 随着数据不断的增加，数据库文件的大小会不断的增加
    ///但是： 如果删除了数据，数据库大小，不会变小！
    ///如果要变小
    ///1>将数据库文件复制一个新的副本，status.db.old
    ///2>新建一个空的数据库文件
    ///3>自己编写SQL，从old中将所有数据读出写入新的数据库
    @objc private func clearDBCache(){
        let dateString = Date.cz_dateString(delta: maxDBCacheTime)
        print("清理数据缓存\(dateString)")
        //准备 SQL
        let sql = "DELETE FROM T_Status WHERE createTime < ?;"
        //执行 SQL
        queue.inDatabase { (db) in
            if db.executeUpdate(sql, withArgumentsIn: [dateString]) == true{
                print("删除了\(db.changes )条记录")
            }
        }
        
        
        
        
    }
}

//MARK: - *********************************创建数据表以及其他私有方法*********************************
 extension CZSQLiteManager{
   
//MARK: -*********************************查询方法*********************************
    func execRecordSet(sql:String) -> [[String:AnyObject]] {
        //结果数组
        var result = [[String:AnyObject]]()
        queue.inDatabase { (db) in
            guard let rs = db.executeQuery(sql, withArgumentsIn: []) else{
                return
            }
            //逐行遍历结果集合
            while rs.next(){
                //1>列数
                let colCount = rs.columnCount
                
                
                //2.>遍历所有列
                for col in 0..<colCount{
                    //3>列名 - KEY
                    //   值 -> Value
                  guard  let name = rs.columnName(for: col),
                    let value = rs.object(forColumnIndex: col)else{
                        continue
                    }
                    
                    //4>追加结果
                    result.append([name : value as AnyObject])
                   // print(name,value)
                }
            }
        }
        return result
    }
    
    
  //MARK: -*********************************创建数据表*********************************
    func createTable() {
        //1.SQL
        guard let path = Bundle.main.path(forResource: "status.sql", ofType: nil),
              let sql = try? String.init(contentsOfFile: path)//创建表的SQL语句
            else {
            return
        }
        print(sql)
        //2.执行 SQL - FMDB 的内部队列，串行队列，同步执行
        queue.inDatabase { (db) in
            if db.executeStatements(sql) == true{
                print("创表成功")
            }else{
                print("创表失败")
            }
        }
    }
}


























