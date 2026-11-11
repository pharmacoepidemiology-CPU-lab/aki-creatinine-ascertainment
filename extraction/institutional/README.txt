三院血清肌酐及手术协变量提取：R 代码校正版 v3（2026-11-08）

本包只包含 R 代码及本说明，用于 NJF、AHMU、ZD 的两类导出。
对应已完成 AHMU 性别、手术级别编码及 ASA 空格修正的六份 CSV。
已按用户确认修正 ICU 标志：有有效入室时间为 1；无有效入室时间为未知，导出为空值。
时间解析和肌酐纳入范围沿用此前已确认规则；双方输出并非完全一致。
不包含患者数据，不包含其他语言的代码，也不执行 AKI/AKD 事件判定或建模。

文件用途
config.R：数据路径、输出路径及已确认的提取参数。
run_extraction.R：先预检查，再从标准化表重新提取两类文件。
helpers.R：共用函数，包含三列关联、字符编号、日期解析、血清肌酐筛选及性别编码修正。
check_outputs.R：核验六份 CSV；重新从 01/03/13 表重建并比较全部协变量，核对肌酐行数、字段、患者/手术关联和相对时间。
apply_icu_unknown.R：本次一次性 ICU 标志修正；先 --validate-only，再 --apply，仅把由无有效入室时间推得的 0 改为空，并保留备份。当前文件已修正后，无需再运行本脚本。

当前六份交付文件所在目录
G:\麻醉数据集\肌酐记录_1105
NJF_episode_covariates.csv       210,179 行
NJF_creatinine_series.csv        626,773 行
AHMU_episode_covariates.csv      337,357 行
AHMU_creatinine_series.csv       565,106 行
ZD_episode_covariates.csv        324,573 行
ZD_creatinine_series.csv         712,538 行
上述均为数据行数，不含表头；协变量每行是一台手术，肌酐每行是一条关联到手术的记录。
现有 CSV 目录名为肌酐记录_1105；AHMU 性别、手术级别及 ASA，以及三院 ICU 标志已在 2026-11-08 更新。修正不改变行数。

运行环境
R：D:\R-4.3.3\bin\Rscript.exe
依赖：data.table、jsonlite、DBI、duckdb。
沿用本机 R 包库 D:/ResearchData/ZD_RLIB_ASCII；不自动安装依赖，不修改系统环境，不启动 RStudio。
脚本和配置为 UTF-8；导出 CSV 为 UTF-8-BOM。编号按字符处理，保留前导零。

路径设置
config.R 中 input_root 指向 G:/麻醉数据集/标化数据整合。
existing_output_root 指向上述现有六份文件，用于 --current 核验。
output_root 默认指向新的 G:/麻醉数据集/肌酐记录_R版重新提取_20261108，仅在真正重提取时创建。
audit_root 指向 D:/ResearchOutput/AKI_ICU_Unknown_20261108，只保存汇总和核验记录。
换电脑或目录时，修改配置中的对应路径。重新提取应使用新的输出目录，已有同名结果时脚本会停止。

运行方法（PowerShell）
假设代码位于 D:\CodexProjects\AKI_R_Release_20261108；解压至其他目录时替换命令中的脚本绝对路径。

只核验当前交付文件：
& 'D:\R-4.3.3\bin\Rscript.exe' 'D:\CodexProjects\AKI_R_Release_20261108\check_outputs.R' --current

需要重新提取时，先预检查：
& 'D:\R-4.3.3\bin\Rscript.exe' 'D:\CodexProjects\AKI_R_Release_20261108\run_extraction.R' --validate-only
预检查通过后提取三院：
& 'D:\R-4.3.3\bin\Rscript.exe' 'D:\CodexProjects\AKI_R_Release_20261108\run_extraction.R' --export
也可以只提取一个医院，例如：
& 'D:\R-4.3.3\bin\Rscript.exe' 'D:\CodexProjects\AKI_R_Release_20261108\run_extraction.R' --export AHMU
三院输出齐全后核验新结果：
& 'D:\R-4.3.3\bin\Rscript.exe' 'D:\CodexProjects\AKI_R_Release_20261108\check_outputs.R' --output

提取口径
1. 03 表定义手术记录；01、03、13 表按 PATIENT_ID、VISIT_ID、OPER_ID 三列关联并按三列去重。
2. 排除无法关联的缺失编号记录；不以是否有肌酐结果筛除协变量表中的手术。
3. 手术时间依次取有效的手术开始、麻醉开始、入室时间；可解析的纯日期表示为当天零点。
4. 检验时间依次取有效标本接收、结果、报告时间；0001 年等占位日期视为缺失。
5. 正确处理日/月/年等源格式，保留已有时分秒；不依赖混合格式的默认日期猜测。
6. 用患者编号和术前 365 天至术后 90 天窗口关联化验，包含端点。
7. 排除明确非血液标本、尿液、比值、清除率等项目；仅接受可明确识别的 umol/L、μmol/L、mg/dL 规范变体。
8. 保留 5 < 浓度（umol/L）< 4000，按 88.42 换算为 mg/dL。
9. 导出阶段保留源表重复化验，供后续项目流程处理；本包不改变已确认的去重、筛选及时间定义。
10. AHMU 人口学 SEX 字段明确按 GB18030 读取，修正女性被误读为空值的问题。
11. AHMU 手术表 OPERATION_SCALE 明确按 GB18030 读取，恢复被误读的“一”；ASA 去除“级”后再次清理首尾空格。
12. ICU 入室时间使用相同的有效日期解析规则。有有效时间记为 1；缺失、占位或无法解析时留空。缺少证据不编码为未入住 ICU。

版本边界
本包已修正 AHMU 性别 176,139 行、手术级别 1,525 行及 ASA 1 行。三类修正仅改变字段值，不改变纳入手术或肌酐记录。
三院 ICU 标志按用户确认由缺少有效入室时间时记 0 改为留空：NJF 195,878 行、AHMU 337,357 行、ZD 324,573 行；NJF 14,301 行有效入室记录仍为 1。AHMU 和 ZD 当前该字段全部未知。
急诊字段仍保留源数值。经核对桌面《麻醉标准数据集 SK_1116.pdf》，第 4 页列名为“数据式例”，第 5 页急诊字段的“0，1”位于该示例列，不构成完整取值限制；第 25 页只给出三院原字段直接对应关系，没有 2–5 的逐值释义或转换规则。不能仅据此将 2–5 判为错误或置空，需明确实际编码含义后再映射。
负 ICU 时长和负出院相对天数仍保留，处理规则尚待确认。不要把本版称为与对方完全一致的版本。
check_outputs.R 的肌酐核验覆盖全部导出记录，不重新扫描大型 09 源表；完整源表提取由 run_extraction.R --export 执行。
日后更新源表或改变提取定义，应重新预检查、提取并核验，不沿用当前固定行数。
