### redis 高并发、高可用

#### 主从复制

主机数据更新后根据配置和策略，自动同步到备机的`master/slave`机制，`master`以写为主，slave以读为主。

* 只需要配置从库，不需要配置主库

##### 如何开启

1. 配置文件

   ~~~shell
   slaveof masterip masterport
   slaveof 127.0.0.1 6379
   ~~~

2. 启动命令

   ~~~shell
   --slaveof masterip masterport
   ~~~

3. 客户端命令

   ~~~shell
   slaveof masterip masterport
   ~~~

##### 如何断开

执行命令

从节点断开复制后，不会删除已有的数据，只是不再接受主节点新的数据变化。

~~~shell
slaveof no one
~~~

#### redis 主从复制的核心原理（全量复制和部分复制）

`redis 2.8`之前从节点向主节点发送`sync`命令请求同步数据，同步方式是全部复制。

`redis 2.8`之后，从节点发送`psync`命令请求数据，根据主从节点当前状态的不同，同步方式可能是全量复制或部分复制。

如果从 `redis` 是新创建的从主 `redis` 中复制全部的数据这是没有问题的，但是，如果当从 `redis` 停止运行，再启动时可能只有少部分数据和主 `redis` 不同步，此时启动 `redis` 仍然会从主 `redis` 复制全部数据，这样的性能肯定没有只复制那一小部分不同步的数据高。

##### 全量复制

* `slave`启动成功连接到`master`后会发送一个`sync`命令

* `master` 启动一个后台进程将数据库快照保存到 `RDB` 文件中（执行`bgsave`），如果 `rdb` 复制时间超过 60秒（`repl-timeout`），那么 `slave`就会认为复制失败

* 注意：此时如果生成 `RDB` 文件过程中存在写数据操作会导致 `RDB` 文件和当前主 `redis` 数据不一致，所以此时 `master` 主进程会开始收集写命令并缓存起来。如果在复制期间，内存缓冲区持续消耗超过 `64MB`，或者一次性超过 `256MB`，那么停止复制，复制失败

* `master` 就发送 `RDB` 文件给 `slave`

* `slave` 接收到`RDB` 文件后，清空自己的旧数据，然后加载到内存恢复

* `master` 把缓存的命令转发给 `slave`

  注意：后续 `master` 收到的写命令都会通过开始建立的连接发送给 `slave`。

* 如果 `slave`开启了 `AOF`，那么会立即执行 `BGREWRITEAOF`，重写 `AOF`。

##### 部分复制

###### offset

* 主节点和从节点分别维护一个复制偏移量（`offset`），代表的是**主节点向从节点传递的字节数**；主节点每次向从节点传播`N`个字节数据时，主节点的`offset`增加`N`；从节点每次收到主节点传来的`N`个字节数据时，从节点的`offset`增加`N`。
* `offset`用于判断主从节点的数据库状态是否一致：如果二者`offset`相同，则一致；如果`offset`不同，则不一致，此时可以根据两个`offset`找出从节点缺少的那部分数据。例如，如果主节点的`offset`是1000，而从节点的`offset`是500，那么部分复制就需要将`offset`为501-1000的数据传递给从节点。而`offset`为501-1000的数据存储的位置
* `offset`保存在 `backlog` 中

###### runid

每个`Redis`节点(无论主从)，在启动时都会自动生成一个随机`ID`(每次启动都不一样)，由40个随机的十六进制字符组成；`runid`用来唯一识别一个`Redis`节点。通过`info Server`命令，可以查看节点的`runid`

###### 过程

从机连接主机后，会主动发起 `PSYNC` 命令，从机会提供 `master` 的 `runid`(机器标识，随机生成的一个串) 和 `offset`（数据偏移量，如果`offset`主从不一致则说明数据不同步），主机验证 `runid` 和 `offset` 是否有效，`runid` 相当于主机身份验证码，用来验证从机上一次连接的主机，如果 `runid` 验证未通过则，则进行全同步，如果验证通过则说明曾经同步过，根据 `offset` 同步部分数据。

##### 复制的完整流程

`slave`启动时，会在自己本地保存 `master`的信息，包括 `master`的`host`和`ip`，但是复制流程没开始。

`slave`内部有个定时任务，每秒检查是否有新的 `master`要连接和复制，如果发现，就跟 `master`建立 `socket` 网络连接。然后 `slave`发送 ping 命令给 master 。如果 `master` 设置了 `requirepass`，那么 `slave` 必须发送 `masterauth` 的口令过去进行认证。`master` 第一次执行全量复制，将所有数据发给 `slave` 。而在后续，`master` 持续将写命令，异步复制给 `slave` 。

##### 过期 key 处理

`slave` 不会过期 `key`，只会等待 `master` 过期 `key`。如果 `master` 过期了一个 `key`，或者通过 `LRU` 淘汰了一个 `key`，那么会模拟一条 `del` 命令发送给 `slave`。

#### 哨兵机制（Sentinel）

用于管理主从复制。

* 集群监控：负责监控 `redis` `master` 和 `slave` 进程是否正常工作。
* 消息通知：如果某个 `redis` 实例有故障，那么哨兵负责发送消息作为报警通知给管理员。
* 故障转移：如果 `master` 挂掉了，会自动转移到 `slave`上。
* 配置中心：如果故障转移发生了，通知 `client` 客户端新的 `master` 地址。

哨兵机制本身必定也是集群方式，单个哨兵是不可靠的。

##### 启动方式

1. ~~~shell
   redis-sentinel /path/to/sentinel.conf
   # redis-sentinel 文件在redis安装目录的src文件夹下
   ~~~

2. ~~~shell
   redis-server /path/to/sentinel.conf --sentinel
   ~~~

这两种方式都必须指定一个`sentinel`的配置文件`sentinel.conf`，默认监听 26379 端口，`sentinel.conf`放在`redis`安装目录下。

`sentinel.conf`配置文件解释

~~~shell
# 监视名为mymaster 地址为127.0.0.1:6379的主机，2代表，当集群中有2个sentinel认为master死了时，才能真正认为该master已经不可用了。（sentinel集群中各个sentinel也有互相通信，通过gossip协议）
sentinel monitor mymaster 127.0.0.1 6379 2

# sentinel down-after-milliseconds与主观下线的判断有关：哨兵使用ping命令对其他节点进行心跳检测，如果其他节点超过down-after-milliseconds配置的时间没有回复，哨兵就会将其进行主观下线。该配置对主节点、从节点和哨兵节点的主观下线判定都有效。
#down-after-milliseconds的默认值是30000，即30s；可以根据不同的网络环境和应用要求来调整：值越大，对主观下线的判定会越宽松，好处是误判的可能性小，坏处是故障发现和故障转移的时间变长，客户端等待的时间也会变长。例如，如果应用对可用性要求较高，则可以将值适当调小，当故障发生时尽快完成转移；如果网络环境相对较差，可以适当提高该阈值，避免频繁误判。
sentinel down-after-milliseconds mymaster 60000

#sentinel failover-timeout与故障转移超时的判断有关，但是该参数不是用来判断整个故障转移阶段的超时，而是其几个子阶段的超时，例如如果主节点晋升从节点时间超过timeout，或从节点向新的主节点发起复制操作的时间(不包括复制数据的时间)超过timeout，都会导致故障转移超时失败。
#failover-timeout的默认值是180000，即180s；如果超时，则下一次该值会变为原来的2倍。
sentinel failover-timeout mymaster 180000

# 这个配置项指定了在发生failover主备切换时最多可以有多少个slave同时对新的master进行同步，这个数字越小，完成failover所需的时间就越长，但是如果这个数字越大，就意味着越 多的slave因为replication而不可用。可以通过将这个值设为 1 来保证每次只有一个slave 处于不能处
sentinel parallel-syncs mymaster 1
~~~

##### 运行机制

​     **需理解概念**

###### 1.主观下线（`Subjectively Down`， 简称 `SDOWN`）

- 在心跳检测的定时任务中，如果其他节点超过一定时间没有回复，哨兵节点就会将其进行主观下线。顾名思义，主观下线的意思是一个哨兵节点“主观地”判断下线；与主观下线相对应的是客观下线。

###### 2.客观下线（`Objectively Down`， 简称 `ODOWN`）

- 哨兵节点在对主节点进行主观下线后，会通过`sentinel is-master-down-by-addr`命令询问其他哨兵节点该主节点的状态；如果判断主节点下线的哨兵数量达到一定数值，则对该主节点进行客观下线。

###### 3.定时任务

每个哨兵节点维护了 3 个定时任务。定时任务的功能分别如下：通过向主从节点发送`info`命令获取最新的主从结构；通过发布订阅功能获取其他哨兵节点的信息；通过向其他节点发送`ping`命令进行心跳检测，判断是否下线。

- 当`sentinel`发送`PING`后，以下回复之一都被认为是合法的，其它任何回复（或者根本没有回复）都是不合法的

  ```
  PING replied with +PONG.
  PING replied with -LOADING error.
  PING replied with -MASTERDOWN error.
  ```

* 从`SDOWN`切换到`ODOWN`不需要任何一致性算法，只需要一个`gossip`协议。
* 如果一个`sentinel`收到了足够多的`sentinel`发来消息告诉它某个`master`已经`down`掉了，`SDOWN`状态就会变成`ODOWN`状态。如果之后`master`可用了，这个状态就会相应地被清理掉。

* `ODOWN`状态只适用于`master`，对于不是`master`的`redis`节点`sentinel`之间不需要任何协商，`slaves`和`sentinel`不会有`ODOWN`状态。

###### 4. 选举领导者哨兵节点

* 当主节点被判断客观下线以后，各个哨兵节点会进行协商，选举出一个领导者哨兵节点，并由该领导者节点对其进行故障转移操作。

* 监视该主节点的所有哨兵都有可能被选为领导者，选举使用的算法是`Raft`算法；`Raft`算法的基本思路是先到先得：即在一轮选举中，哨兵`A`向`B`发送成为领导者的申请，如果`B`没有同意过其他哨兵，则会同意`A`成为领导者。选举的具体过程这里不做详细描述，一般来说，哨兵选择的过程很快，谁先完成客观下线，一般就能成为领导者。

###### 5.故障转移

* 选举出的领导者哨兵，开始进行故障转移操作，该操作大体可以分为 3 个步骤：
  * 在从节点中选择新的主节点：选择的原则是，首先过滤掉不健康的从节点；然后选择优先级最高的从节点(由`slave-priority`指定)；如果优先级无法区分，则选择复制偏移量最大的从节点；如果仍无法区分，则选择`runid`最小的从节点。
  * 更新主从状态：通过`slaveof no one`命令，让选出来的从节点成为主节点；并通过`slaveof`命令让其他节点成为其从节点。
  * 将已经下线的主节点(即 6379 )设置为新的主节点的从节点，当 6379 重新上线后，它会成为新的主节点的从节点。

###### 运行机制

1）每个`Sentinel`以心跳检测向它所知的`Master`，`Slave`以及其他 `Sentinel` 实例发送一个`PING`命令。
2）如果一个实例（`instance`）距离最后一次有效回复`PING`命令的时间超过 `down-after-milliseconds` 选项所指定的值，则这个实例会被`Sentinel`标记为主观下线。 
3）如果一个`Master`被标记为主观下线，则正在监视这个`Master`的所有 `Sentinel` 要以每秒一次的频率确认`Master`的确进入了主观下线状态。 
4）当有足够数量的`Sentinel`（大于等于配置文件指定的值）在指定的时间范围内确认`Master`的确进入了主观下线状态，则`Master`会被标记为客观下线。
5）在一般情况下，每个`Sentinel` 会以每10秒一次的频率向它已知的所有`Master`，`Slave`发送 `INFO` 命令。
6）当`Master`被`Sentinel`标记为客观下线时，`Sentinel` 向下线的 `Master` 的所有`Slave`发送 `INFO`命令的频率会从10秒一次改为每秒一次。 
7）若没有足够数量的`Sentinel`同意`Master`已经下线，`Master`的客观下线状态就会被移除。 若 `Master`重新向`Sentinel` 的`PING`命令返回有效回复，`Master`的主观下线状态就会被移除。

##### 配置版本号

为什么要先获得大多数`sentinel`的认可时才能真正去执行`failover`呢？

当一个`sentinel`被授权后，它将会获得宕掉的`master`的一份最新配置版本号，当`failover`执行结束以后，这个版本号将会被用于最新的配置。因为**大多数**`sentinel`都已经知道该版本号已经被要执行`failover`的`sentinel`拿走了，所以其他的`sentinel`都不能再去使用这个版本号。这意味着，每次`failover`都会附带有一个独一无二的版本号。我们将会看到这样做的重要性。

而且，`sentinel`集群都遵守一个规则：如果`sentinel A`推荐`sentinel B`去执行`failover`，`A`会等待一段时间后，自行再次去对同一个`master`执行`failover`，这个等待的时间是通过`failover-timeout`配置项去配置的。从这个规则可以看出，`sentinel`集群中的`sentinel`不会再同一时刻并发去`failover`同一个`master`，第一个进行`failover`的`sentinel`如果失败了，另外一个将会在一定时间内进行重新进行`failover`，以此类推。

`redis sentinel`保证了活跃性：如果**大多数**`sentinel`能够互相通信，最终将会有一个被授权去进行`failover`.
`redis sentinel`也保证了安全性：每个试图去`failover`同一个`master`的`sentinel`都会得到一个独一无二的版本号。

##### 实践建议

1. 哨兵节点的数量应不止一个，一方面增加哨兵节点的冗余，避免哨兵本身成为高可用的瓶颈；另一方面减少对下线的误判。此外，这些不同的哨兵节点应部署在不同的物理机上。

2. 哨兵节点的数量应该是奇数，便于哨兵通过投票做出“决策”：领导者选举的决策、客观下线的决策等。

3. 各个哨兵节点的配置应一致，包括硬件、参数等；此外，所有节点都应该使用`ntp`或类似服务，保证时间准确、一致。

4. 哨兵的配置提供者和通知客户端功能，需要客户端的支持才能实现，如前文所说的`Jedis`；如果开发者使用的库未提供相应支持，则可能需要开发者自己实现。

5. 当哨兵系统中的节点在`docker`（或其他可能进行端口映射的软件）中部署时，应特别注意端口映射可能会导致哨兵系统无法正常工作，因为哨兵的工作基于与其他节点的通信，而`docker`的端口映射可能导致哨兵无法连接到其他节点。例如，哨兵之间互相发现，依赖于它们对外宣称的`IP`和`port`，如果某个哨兵`A`部署在做了端口映射的`docker`中，那么其他哨兵使用`A`宣称的`port`无法连接到A。

##### Sentinel的通信命令

`Sentinel` 与 `Redis` **主节点** 和 **从节点** 交互的命令，主要包括：

| 命令        | 作用                                                         |
| ----------- | ------------------------------------------------------------ |
| `PING`      | `Sentinel` 向 `Redis` 节点发送 `PING` 命令，检查节点的状态   |
| `INFO`      | `Sentinel` 向 `Redis` 节点发送 `INFO` 命令，获取它的 **从节点信息** |
| `PUBLISH`   | `Sentinel` 向其监控的 `Redis` 节点 `__sentinel__:hello` 这个 `channel` 发布 **自己的信息** 及 **主节点** 相关的配置 |
| `SUBSCRIBE` | `Sentinel` 通过订阅 `Redis` **主节点** 和 **从节点** 的 `__sentinel__:hello` 这个 `channnel`，获取正在监控相同服务的其他 `Sentinel` 节点 |

`Sentinel` 与 `Sentinel` 交互的命令，主要包括

| 命令                              | 作用                                                         |
| --------------------------------- | ------------------------------------------------------------ |
| `PING`                            | `Sentinel` 向其他 `Sentinel` 节点发送 `PING` 命令，检查节点的状态 |
| `SENTINEL:is-master-down-by-addr` | 和其他 `Sentinel` 协商 **主节点** 的状态，如果 **主节点** 处于 `SDOWN` 状态，则投票自动选出新的 **主节点** |

参考：https://juejin.cn/post/6844903663362637832