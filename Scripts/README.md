# 30 张名片数据集评测

本目录提供「30 张测试名片 → 真实 Vision OCR → 字段抽取 → 准确率报告」的完整可复现流程。

## 目录结构

```
ground_truth.json                     30 条 Ground Truth（raw_text + 8 字段 + fax）
Fixtures/Images/TC01.png … TC30.png   30 张测试名片照片（含桌面背景/旋转/噪声/竖排版式）
Fixtures/Images/layout.json           生成参数（角度、行数），便于复现
Fixtures/OCR/TC01.json … TC30.json    OCR 夹具（text / confidence / bbox，mock 识别器可直接读取）
Fixtures/Results/ocr_results.json     端到端采证（图片 → OCR → 字段 + 原文 + 耗时）
Fixtures/Results/parser_results.json  抽取基线（Ground Truth 原文 → 字段）
Fixtures/Results/metrics.json         完整指标 + 错误明细（JSON）
Reports/AccuracyReport.md                准确率报告（Markdown）
Reports/dataset_contact_sheet.png        30 张图片总览图
```

## 评测流程

1. **生成数据**：`Scripts/generate_fixtures.py` 从 `ground_truth.json` 渲染 30 张名片图片，
   同时生成 OCR 夹具；版式包含标准横版、双语、多行地址、竖排（TC07）、
   扫描噪声（TC30）、轻微旋转（TC09/TC16/TC19/TC24/TC25）等变体。
2. **采证**：`EvaluationEvidenceTests` 用 App 同一条流水线
   （Vision 区域检测 → 透视校正 → Vision OCR → CardFieldParser）逐张识别，
   写出端到端结果与抽取基线。
3. **评测**：`Scripts/evaluate.py` 做字段级归一化、Precision/Recall/F1 计算、
   空值正确率与错误归因，输出 Markdown 报告与 JSON 指标。

## 复现命令

```bash
# 1) 图片 + OCR 夹具（需要 Pillow；本机使用带 Pillow 的 Python 解释器）
python3 Scripts/generate_fixtures.py

# 2) 图片 → Vision OCR → 字段抽取（需要 Xcode；macOS Vision 需完整磁盘访问）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-sandbox --filter EvaluationEvidenceTests

# 3) 计算指标并生成报告
python3 Scripts/evaluate.py

# 一键执行（3 步串联）
bash Scripts/run_evaluation.sh
```

## 指标定义

- **字段级准确率**：30 条样例中，该字段与 Ground Truth 归一化后完全一致的比例；
  空值 == 空值 也计为正确。
- **Precision / Recall / F1**：以「Ground Truth 非空」为正例；
  TP 要求预测非空且与期望一致。
- **空值正确率**：Ground Truth 为空时，预测也必须为空（不得虚构）。
- **归一化**：姓名/公司/职位/地址忽略空白；邮箱小写；网址去 scheme 与尾斜杠；
  电话只保留数字并按 ` / ` 拆分多值比较。
- **验收口径**：spec §4.2（姓名/公司/手机/邮箱 ≥95%、宏平均 F1 ≥90%、空值正确率 100%）
  以「抽取层」（Ground Truth 原文 → 字段）为准；端到端指标包含 OCR 误差，
  用于错误归因，不直接作为验收门槛。

## 已知限制

- 图片为合成渲染，光照/运动模糊/复杂背景与真实拍摄仍有差距；
- 竖排中文（TC07）是 Vision OCR 的已知弱项，自动化识别率偏低，
  产品侧以「手动调整边角 + 人工校对」兜底；
- `fax` 字段当前解析结果模型未暴露，未纳入 8 字段指标（T10 已单独验证传真不串号）；
- 未与闭源参考 App（CamCard）做逐样例自动对比。
