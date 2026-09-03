# Agent Note: Profile 模块后备按安装代隔离

Status: implemented

[English](2026-08-29-profile-installation-generation-isolation.md) | 中文

## 问题

共享同一 Harness home 的每个 dsh 安装，都会把一个扁平的跨 profile 目录——`$DSH_HOME/profiles/node_modules`——heal 成自己的依赖闭包，最后写入者获胜。组合树的 `baseUrl` 锚在 profile 根，于是整棵树的每一行（bundle 行、用户 patch 行，以及经 preset 挂载记录基准解析的 agent preset 行）都穿过这唯一共享目录解析。第二个更旧的安装对同一 home 启动时，会在第一个安装脚下改写闭包：选择 `mode: ptc` 的 preset 面对旧安装重命名前的插件，schema 校验失败。新鲜度检查（`moduleFallbackEntryCurrent`）逐字比较链接文本，等价写法的链接也会在每次启动时搅动跨进程锁；而同目录上两个安装的竞争没有任何结构性防御。

## 决策

安装依赖闭包改为**每 profile 每安装代**。profile 增加一个 `.dsh-generations/<安装 id>/` 目录，`<安装 id>` = `installationGenerationId(installAnchor)`——规范化安装目录的 slug 加短 SHA-256——其中保存：

- 组合树的空 root 配置（`cordis.yml`），`prepareProfile` 照旧每次启动重写，只是位置移入代目录。`boot()` 把 `ctx.baseUrl` 锚在 root 配置所在目录，因此整棵树——连同 preset 挂载记录的基准——都安装优先地穿过 `<代目录>/node_modules` 解析；
- heal 出的闭包（`<代目录>/node_modules`），`healProfilesModuleFallback` 现在把链接（普通 Node 的 symlink、打包可执行文件的 ESM 代理）写在锁按代隔离的这里。

`healProfilesModuleFallback` 现在要求传入已加载 profile（`home` 选项删除——所有消费方都改为传入已加载 profile：CLI preset e2e、web 测试 scaffold、`start-dsh` 预检），`profileGenerationDir(profile, installAnchor)` 是 healer、boot、config dump 共用的唯一目录计算。旧扁平目录 `$DSH_HOME/profiles/node_modules` 不再被写入；它在 Node 父目录查找中仍位于 profile 自身 `node_modules` 之后，作为既有树外安装及其 pnpm override 可能读取的遗留槽位，launcher 不再拥有它。取代 [profile 插件 bundle](2026-08-05-profile-plugin-bundles.zh.md) 的解析段落；`.dsh-module-fallback` 的 bundle 专属投影不变。

## 备选方案

- **保留共享目录，代不匹配时报错**: 旧安装正是污染状态的写入方，它无法学会检查一个它诞生之前才发明的标记——防御必须把状态移出旧二进制会写的路径。
- **preset 行直接锚在安装本体**（从安装目录解析 `@deepseek-ai/*`）: 只修好 preset 行，组合树其余部分仍留在共享目录上，且需要新的跨包接缝把安装路径带进 `agent-presets`。移动 root 配置则一次移动所有行的基准，不新增接缝。

## 后果

- 共享同一 Harness home 的两个 dsh 安装不再可能改写彼此的依赖闭包；PTC 模式失败这类「preset 行加载到别的安装的插件」被结构性关闭，而非靠卫生习惯。
- 每个 profile 会为运行过它的每个安装累积一个小目录（仅闭包链接）；已卸载安装的陈旧代目录是惰性残留，可手工删除。
- 社区插件的 harness peer 导入在 profile `node_modules` 缺包时仍落到遗留共享槽位；该偏差先于本次变更，保持不变。
