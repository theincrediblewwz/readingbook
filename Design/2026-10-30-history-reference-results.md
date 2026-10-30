# 0.23.20 · 历史引用定位与隐藏渲染对照

本批采用历史引用定位修复。产品源`6408ab4a4cd65deced124691fd92c2e5883ffd85`已同步main，[完整CI41024746938](https://github.com/theincrediblewwz/readingbook/actions/runs/41024746938)通过706 Core零失败/零编译警告、49具名和全部旧门槛及新增70项历史守护；[0.23.20/build51](https://github.com/theincrediblewwz/readingbook/releases/tag/v0.23.20)已发布并替换本机安装版。没有采用隐藏Markdown延后排版候选；0.23.19的笔记、搜索及此前优化均保留。

## 修复实际定位错误

原版通过书内链接打开第59条历史回答时，实际可见的是第56条。六十条和一千条合成历史均出现定位不正确；45秒测试超时只表示目标没有可见，不能说主线程冻结了45秒。一次scrollTo与异步Markdown高度的组合会漂移；绑定滚动ID的候选初次定位虽有改善，调整宽度后仍可能偏移。默认锚点与typed ScrollPosition两候选也有实际失败，未采用。

最终从引用进入时，让目标回答成为初始显示范围的第一条，向后最多60条；通过“显示更早／后续的对话”按60条扩展。原顺序、完整项目、所有聊天内容均保留；普通历史入口仍从最后60条开始。只有新引用重置滚动容器，字号、宽度、普通数据刷新不会追着引用把用户拉回。按钮有说明气泡，范围向辅助功能公开。

真实EnhancedBookChatView → 内部链接 → 历史sheet的六组场景通过70项具名守护：60/1000条、最早/中间/靠后/末条定位；字号、实际窗口宽度变化、同一回答内已滚动后再次调整宽度、另一原生滚动和无关刷新；真实WK与完整DOM、原文映射、revision及项目/笔记/草稿字节保持。未使用真实书库或真实模型。

额外分页检查的进程内NSAccessibility遍历未能读取SwiftUI虚拟节点，失败保留；未将其冒称为产品故障或通过的UI验证。随后改用真实CUA在同一产品源的独立1000条合成库实际点击：8次向后、9次向前，范围扩展至1–1000；首条原文与末条RBH-END-history-000999截图可达。没有把这17次实际点击伪计进70项自动守护。CI新增同一70项守护，原29项桥接、152项来源字节、706 Core/49具名及全部旧门禁继续保留。

## 明确拒绝一项性能候选

隐藏surface只保留最后一次CSS，确实减少了预检中的后台CPU。但128KiB场景重新显示约104→453ms，多约349ms，超过事先设定的20%且50ms回退门槛，因此拒绝。20KiB与128KiB各两臂，共4个新进程；这是预检，不是36进程正式采用实验，也不宣称稳定整体提速。完整源码、DOM、selection、权限与所有时钟均保存并独立复核。

测试工具两项可见区断言和一项诊断arm标签误入语义比较已修正，旧失败全部保留。实际NSView.visibleRect可能超出本view边界，需要与own bounds求交；固定host尺寸后再验证原生裁剪与DOM标题。跨臂只排除已独立校验正确值的probe arm标签，每份完整原始值的hash和其余所有语义字段仍核验。

短时合并、空闲后在后台补一次排版是后续思路，尚未实现或采用；不把耗时从后台挪到用户打开时当作优化。其余16类组件、跨组件交流和长时任务计划继续。

## 证据与保护

原始证据均在工作区logs/webkit-history-20261030。产品patch及70项通过契约见HistoryReferenceWindow-shadow.patch、history-native-final-contract.json；性能预检见ab-pilot-03及其analysis-probe-label-fixed.json。产品只改历史显示范围和相应CI，MarkdownRenderer与ReadingViews没有采用本批CSS改动。

开发源、构建、cache、日志与保护仍限本工作目录；原书、笔记、分析及偏好保留。安装前已重新保护当时最新20文件书库、全部偏好和旧19 App。安装后原书/笔记/分析字节及全部偏好保持，仅正常Workspace导航更新；没有用旧库覆盖现库。


## 最终交付与原书验收

canonical ZIP为25,173,896B，SHA256 `32f5a3182d37348b1f2a6b58eb42fc8322e550bca79ef91eb230cf1da30e6cb0`。两层ZIP、Actions artifact12964487141、远端Release428808064的摘要、包内源/版本、arm64+x86_64、严格签名、32资源和36文件清单均通过。本机About实际为0.23.20(51)。

实际原书103页/343%、同书重选和两次正常重启；102页已有句译；伴读/对话、建议、Unicode粘贴/Undo/Redo、收起草稿/焦点、历史/记忆窗口；简繁各57、关闭搜索回103、点击首条到92；笔记/回收站从reader和library关闭返回原界面均通过。测试输入已清空，伴读收起；未真实AI生成或创建/保存真库笔记。原书实际没有已保存对话，所以没有冒称在真库点击了不存在的历史引用；新引用正确性由真实原生CI70与独立合成CUA验证。

两次重启PID5840/5871有现场ps确认的Applications路径。首次完整UI进程5746通过统一日志与安装Macho UUID对应；统一日志将相同UUID映射到先前CI解包路径，这对后两次已确认Applications的进程也一样，因此不从该缓存路径推断首次物理路径。三进程的全量信息日志均未发现300 iterations、发布视图内变更、AttributeGraph循环这三类告警。完整证据含此边界；一次UI回执字段名不匹配已按实际观察改名重验，失败回执保留。

最新保护为`private-books/webkit-history-20261030/install-before-0.23.20/`，保留19 App回滚和19/20 canonical包；9个更旧App与18旧包已退役，所有非App的私有数据/偏好备份字节保持。GitHub仅main和20/19两版Release/tag/Actions资产，18已按精确源与摘要核对后清理，提交历史仍保留。

旧展开测试树与本批实际App/已链接helper、来源树均完成CRC/SHA核验归档后退役，恢复入口分别为logs/webkit-history-20261030/cleanup-old-generated与cleanup-current-replay里的pack-generated-trees.py restore。先恢复再用旧原路径复核，不能把退役的对象树说成仍可逐对象重审；可重建编译对象和dSYM已清理，主线Debug及共享模块cache保留。正式性能36进程没有运行，不能把该恢复包叫作正式收益实验。

按du -sk，工作区全批约6.13→4.21GiB，净减少约1.93GiB；这是包含保留归档、最新保护与证据的整个工作区变化，不把各阶段删除量相加当净节省，也不推断APFS物理空闲空间。最终验收`logs/webkit-history-20261030/delivery/final-delivery-v2.json`已completed。所有新开发产物仍在本工作目录内。
