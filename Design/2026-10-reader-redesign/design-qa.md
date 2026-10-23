# 0.14 交互核对

2026-10-23。目标为同目录三张已确认效果稿。实现沿用霜银/钴蓝、原文优先、悬浮工具和可关闭面板。证据是浏览器交互稿，不是 Mac 原生截图；示例历史文字与地形不作为事实来源。

| 场景 | 已观察结果 |
| --- | --- |
| 1440×1024 阅读 | 原文主体、右侧伴读、独立提问范围与单组底部工具 |
| 1280×720 回答 | 选择全书并发送后，翻页不改变本次回答的冻结范围 |
| 翻页的默认伴读 | 引句来自当前页，不把第一页引句标成第二、三页 |
| 800×600 | 伴读正文内部滚动，底部动作不再被提问框盖住；关闭后出现恢复入口 |
| 读书方法 | 默认显示书型、方法步骤与一条任务状态；处理详情默认收起 |
| 伴读、读法面板 | 关闭、恢复和收起可操作，不需要关闭浏览器 |
| 人物时空 | 一根轴有两个范围端点及一个当前时间指针；键盘和拖动均可改变当前时间 |
| 曹操示例 208→209 | 人物卡和地图同时变化；没有记录的时点不沿用旧位置 |
| 人物浮窗 | 已实际从左侧拖到右侧，地图仍铺满内容区 |
| 浏览器错误 | 本次已观察交互中控制台 error 为 0 |

发现并修复：低高度伴读操作被输入框覆盖、回答标题没有使用冻结范围、翻页后默认引句取错页。原生另处理章级增强检查点、防止只读提问继承整理授权，以及多挂载节点/时态对象删除的关联清理。原生鼠标接收、键盘、Liquid Glass 和系统窗口表现仍由 Mac 集中验收。

截图：

- `../prototype-frost/evidence/revision-0.14/reader-wide.png`
- `../prototype-frost/evidence/revision-0.14/reader-720-frozen-book.png`
- `../prototype-frost/evidence/revision-0.14/reader-800x600.png`
- `../prototype-frost/evidence/revision-0.14/method-wide.png`
- `../prototype-frost/evidence/revision-0.14/entity-map-wide.png`
- `../prototype-frost/evidence/revision-0.14/entity-209-no-location.png`

MapKit 的虚线出现次序采用 Apple 的 [MapPolyline](https://developer.apple.com/documentation/mapkit/mappolyline) 接口；它连接已有、可排序的出现点，不作为真实路线。未知/有争议时间及同精度时间并列的点不据此推造移动先后。

原生构建证据：源码 `18128f4ef69ececefcf030a4f8c9384b0384acaa` 的 [Actions 39946215789](https://github.com/theincrediblewwz/readingbook/actions/runs/39946215789) 成功，200 项 Core 检查和 arm64/x86_64 Release、临时签名、资源自检通过，无编译警告。0.14.0/build17 下载包的摘要、CRC、版本/源码、双架构/执行权限与全部 32 个资源已核对。这证明可编译与打包，不把上述浏览器截图当作原生视觉通过；Mac 集中清单全部待用户操作。
