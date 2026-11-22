# ⚠️ 归档分支 x86_64-legacy（请勿使用）

**此分支已于 2026-11-23 归档，仅作历史参考。**

## 为什么归档

这个分支是 2026-11-16 为了让 Intel Mac 能用 Zeroflow 而做的改动：

| 改动 | 内容 |
|---|---|
| `.github/workflows/build.yml` | 加 `workflow_dispatch:` 触发器 |
| `Zeroflow.xcodeproj/project.pbxproj` | Debug/Release 各加 `ARCHS = x86_64;`，Debug 另设 `ONLY_ACTIVE_ARCH = NO` |

**上游后来自己解决了这个问题：**

- 2026-11-18，issue #28（by @Eren330）提出 Intel 支持需求
- 同日，上游 commit `918e017d`「增加编译x86版本」
- 2026-11-21 发布 v1.6.1，**首次直接提供 `Zeroflow-1.6.1-x86_64.dmg`**

**上游现在的做法更优：**

```yaml
matrix:
  - arch: arm64
    archs: arm64
  - arch: x86_64
    archs: x86_64
```

通过矩阵参数传 `ARCHS`，一次编译两个架构，**不需要改 `project.pbxproj`**，还带 `lipo -archs` 架构验证。

## 所以

- **不要再基于此分支构建** —— 上游发布的官方 x86_64 包更好
- **不要把此分支同步到上游** —— 改动是多余的
- **保留它只是为了**：万一上游某天又停止发布 x86_64，这里有一套可用的历史方案

## 历史产物

本分支的 CI 曾成功构建（run #1，2026-11-16 18:15），产物已发布于：

https://github.com/cccccchhhh899789/zeroflow/releases/tag/v1.5.10-x86c

（对应 Zeroflow v1.5.10，Intel x86_64 自编译版）

---

2026-11-23 归档 by DSH session
