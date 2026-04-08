# OSSClient Multi-Instance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the singleton-based `OSSClient` API with an instance-based API that allows multiple clients to connect to different buckets at the same time.

**Architecture:** Convert `OSSClient` from a global singleton into a regular class with per-instance state. Preserve the existing operational methods and mixins, but move initialization into an instance constructor/factory so each client owns its own config, request handler, signing strategies, and request manager.

**Tech Stack:** Dart, Dio, package:test

---

### Task 1: Lock multi-instance behavior with tests

**Files:**
- Modify: `test/ali_yun_oss_test.dart`
- Modify: `test/cname_test.dart`
- Modify: `test/query_params_test.dart`

**Step 1: Write the failing test**

Add tests asserting:
- two `OSSClient` instances can be created with different configs
- each instance keeps its own `config.bucketName`
- URI building and signed URL generation use the correct instance config

**Step 2: Run test to verify it fails**

Run: `dart test test/ali_yun_oss_test.dart test/cname_test.dart test/query_params_test.dart`
Expected: FAIL because `OSSClient.init` / `OSSClient.instance` semantics no longer match the desired multi-instance behavior.

**Step 3: Write minimal implementation**

Replace singleton entry points with instance construction and update tests to call the new API.

**Step 4: Run test to verify it passes**

Run: `dart test test/ali_yun_oss_test.dart test/cname_test.dart test/query_params_test.dart`
Expected: PASS

**Step 5: Commit**

```bash
git add test/ali_yun_oss_test.dart test/cname_test.dart test/query_params_test.dart lib/src/client/client.dart
git commit -m "feat: support multi-instance oss clients"
```

### Task 2: Refactor OSSClient to instance-based initialization

**Files:**
- Modify: `lib/src/client/client.dart`

**Step 1: Write the failing test**

Covered by Task 1.

**Step 2: Run test to verify it fails**

Covered by Task 1.

**Step 3: Write minimal implementation**

Implement an instance constructor or factory that:
- validates config
- creates per-instance Dio/request handler/sign strategy state
- removes `_instance`, `_initialized`, `instance`, and `init`

**Step 4: Run test to verify it passes**

Run: `dart test test/ali_yun_oss_test.dart test/cname_test.dart test/query_params_test.dart`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/src/client/client.dart
git commit -m "refactor: remove singleton oss client"
```

### Task 3: Update docs and examples

**Files:**
- Modify: `README.md`
- Modify: `README_zh.md`
- Modify: `example/example.dart`
- Modify: `example/query_params_example.dart`
- Modify: `example/cname_demo.dart`

**Step 1: Write the failing test**

No automated doc test in repo; rely on analyzer and targeted test suite.

**Step 2: Run verification**

Run: `dart analyze`
Expected: no errors from removed singleton API usage.

**Step 3: Write minimal implementation**

Update all public examples and docs from `OSSClient.init(...)` / `OSSClient.instance` to direct instance creation.

**Step 4: Run verification**

Run: `dart test`
Expected: PASS

**Step 5: Commit**

```bash
git add README.md README_zh.md example/example.dart example/query_params_example.dart example/cname_demo.dart
git commit -m "docs: update oss client usage for multi-instance api"
```
