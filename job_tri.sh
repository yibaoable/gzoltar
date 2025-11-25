#!/bin/bash
# 脚本功能：自动化处理Defects4J缺陷项目，使用GZOLTAR工具收集代码覆盖率并生成故障定位报告
# export GZOLTAR_CLI_JAR=/root/gzoltar_1.7.3/lib/gzoltarcli.jar GZOLTAR_AGENT_JAR=/root/gzoltar_1.7.3/lib/gzoltaragent.jar

# ============================== 基础变量定义 ==============================
# 获取当前脚本执行目录
SCRIPT_DIR=$(pwd)

# 接收外部传入参数：PID（Defects4J项目ID，如Lang、Math）、BID（缺陷ID，如1、2）
PID=$1
BID=$2

# 定义缺陷项目的工作目录路径：格式为"PID_BID_bug"，用于存放检出的缺陷版本代码
PROJECT_DIR=/tmp/${PID}_${BID}_bug

# ============================== 检出Defects4J项目 ==============================
# 从Defects4J检出指定项目、指定缺陷版本的代码到工作目录（-v ${BID}b 表示buggy版本）
defects4j checkout -p ${PID} -v ${BID}b -w ${PROJECT_DIR}

# 进入工作目录，后续操作均基于该目录执行
cd ${PROJECT_DIR}

# 编译缺陷项目代码（确保后续覆盖率收集和测试执行无编译错误）
defects4j compile

# 导出项目关键目录路径：
# dir.bin.classes：编译后的主程序类文件目录（.class文件）
# dir.bin.tests：编译后的测试类文件目录（.class文件）
# cp.test：测试执行所需的类路径（包含依赖库、主程序类、测试类）
SRC_DIR=${PROJECT_DIR}/$(defects4j export -p dir.bin.classes)
TEST_DIR=${PROJECT_DIR}/$(defects4j export -p dir.bin.tests)
LIB_DIR=$(defects4j export -p cp.test)

# ============================== 筛选相关测试用例 ==============================
# 定义Defects4J中该缺陷对应的"触发测试用例"文件路径
SELECTED_TESTS_FILE=${D4J_HOME}/framework/projects/${PID}/trigger_tests/${BID}

# 处理触发测试用例：
# 1. 提取以"--- "开头的行（包含测试类和方法信息）
# 2. 移除"--- "前缀
# 3. 将"::"替换为"#"（GZOLTAR格式）
# 4. 每行末尾添加"#*"（GZOLTAR识别的测试方法通配符格式）
# 5. 将换行符替换为冒号（GZOLTAR --includes参数要求的分隔符格式）
RELEVANT_TESTS=$(grep "^--- " ${SELECTED_TESTS_FILE} | sed 's/^--- //' | sed 's/::/#/' | sed ':a;N;$!ba;s/\n/:/g')
# RELEVANT_TESTS=$(grep "^--- " ${SELECTED_TESTS_FILE} | sed 's/^--- //' | sed 's/::/#/' | sed 's/$/#*/' | sed ':a;N;$!ba;s/\n/:/g')
# echo "选定的触发测试用例（GZOLTAR格式）："
# echo "${RELEVANT_TESTS}"
# ============================== 列出目标测试方法 ==============================
# 使用GZOLTAR CLI工具列出指定测试目录下的所有测试方法，仅包含相关测试用例
# 输出文件：listTestMethods.txt（记录待执行的测试方法列表）
java -cp ${LIB_DIR}:${GZOLTAR_CLI_JAR} \
  com.gzoltar.cli.Main listTestMethods \
  ${TEST_DIR} \
  --outputFile ${PROJECT_DIR}/listTestMethods.txt \
  --includes ${RELEVANT_TESTS}  # 仅筛选相关测试用例

# ============================== 定义覆盖率收集范围 ==============================
# GZOLTAR生成的覆盖率数据文件（.ser格式，包含执行轨迹和覆盖率信息）
SER_FILE=${PROJECT_DIR}/gzoltar.ser

# 定义Defects4J中该缺陷对应的"已加载主程序类"文件路径（排除无关类，减少覆盖率收集开销）
LOADED_CLASSES_FILE=${D4J_HOME}/framework/projects/${PID}/loaded_classes/${BID}.src

# 构建覆盖率收集的类过滤规则：
# 1. 正常类：原类名后加":"（分隔符）
# 2. 内部类：原类名后加"$*:"（匹配所有内部类，如A$B、A$C）
# 3. 合并正常类和内部类规则，作为GZOLTAR的includes参数
NORMAL_CLASSES=$(cat ${LOADED_CLASSES_FILE} | sed 's/$/:/' | sed ':a;N;$!ba;s/\n//g')
INNER_CLASSES=$(cat ${LOADED_CLASSES_FILE} | sed 's/$/$*:/' | sed ':a;N;$!ba;s/\n//g')
LOADED_CLASSES=${NORMAL_CLASSES}${INNER_CLASSES}

# ============================== 执行测试并收集覆盖率 ==============================
# 使用GZOLTAR Agent（Java代理）执行测试方法，收集代码覆盖率：
# -javaagent：指定GZOLTAR代理，配置覆盖率数据输出文件、主程序类目录、过滤规则等
# runTestMethods：GZOLTAR命令，执行指定的测试方法列表
# --collectCoverage：启用覆盖率收集功能
java -javaagent:${GZOLTAR_AGENT_JAR}=destfile=${SER_FILE},buildlocation=${SRC_DIR},includes=${LOADED_CLASSES},excludes="",inclnolocationclasses=false,output="file" \
  -cp ${GZOLTAR_CLI_JAR}:${LIB_DIR} \
  com.gzoltar.cli.Main runTestMethods \
  --testMethods ${PROJECT_DIR}/listTestMethods.txt \
  --collectCoverage 

# ============================== 生成故障定位报告 ==============================
# 使用GZOLTAR生成故障定位（SFL）报告：
# --granularity method：覆盖率粒度为方法级
# --inclPublicMethods：包含公共方法
# --inclStaticConstructors：包含静态构造方法
# --inclDeprecatedMethods：包含过时方法
# --family sfl：生成故障定位相关报告
# --formula ochiai：使用Ochiai公式计算可疑度（故障定位常用公式）
# --metric entropy：计算熵值指标（辅助评估定位效果）
# --formatter txt：输出TXT格式报告（便于后续文件处理）
java -cp ${GZOLTAR_CLI_JAR}:${LIB_DIR} \
  com.gzoltar.cli.Main faultLocalizationReport \
    --buildLocation ${SRC_DIR} \
    --granularity method\
    --inclPublicMethods \
    --inclStaticConstructors \
    --inclDeprecatedMethods \
    --dataFile ${SER_FILE} \
    --outputDirectory ${PROJECT_DIR} \
    --family sfl \
    --formula ochiai \
    --metric entropy \
    --formatter txt

# ============================== 关键文件归档 ==============================
# 定义GZOLTAR生成的核心文件路径：
# matrix.txt：覆盖率矩阵（行=测试用例，列=代码行，值=是否覆盖）
# spectra.csv：代码谱（记录每个代码行对应的类、方法信息）
# tests.csv：测试结果（记录每个测试用例的执行结果：PASS/FAIL）
RANKING_FILE=${PROJECT_DIR}/sfl/txt/ochiai.ranking.csv
MATRIX_FILE=${PROJECT_DIR}/sfl/txt/matrix.txt
SPECTRA_FILE=${PROJECT_DIR}/sfl/txt/spectra.csv
TESTS_FILE=${PROJECT_DIR}/sfl/txt/tests.csv
STATISTICS_FILE=${PROJECT_DIR}/sfl/txt/statistics.csv

# 定义归档目录：按"项目ID/缺陷ID"分级存储，确保文件组织有序
ARCHIVE_DIR=/root/locate_result/exec_info_trigger/${PID}/${BID}
mkdir -p ${ARCHIVE_DIR}  # 递归创建目录（若父目录不存在则自动创建）

# 归档核心文件并预处理：
# 1. 直接移动覆盖率矩阵文件
# 2. 移除spectra.csv的表头（保留数据行）
# 3. 移除tests.csv的表头（保留数据行）
mv ${MATRIX_FILE} ${ARCHIVE_DIR}/matrix
# mv ${STATISTICS_FILE} ${ARCHIVE_DIR}/statistics
mv ${RANKING_FILE} ${ARCHIVE_DIR}/ranking.csv
tail -n +2 ${SPECTRA_FILE} > ${ARCHIVE_DIR}/spectra  # tail -n +2：从第2行开始输出（跳过表头）
tail -n +2 ${TESTS_FILE} > ${ARCHIVE_DIR}/tests


# ============================== 光谱文件（spectra）清理 ==============================
# 清理目的：使spectra文件中的类名格式与.java源文件一致，便于后续分析（如关联源码）
# 1. 移除内部类的嵌套层级（如A$B$C# → A$B#）
sed -i -E 's/(\$\w+)\$.*#/\1#/g' ${ARCHIVE_DIR}/spectra
# 2. 移除方法名（仅保留类名和代码行，格式：类名#行号）
sed -i 's/#.*:/#/g' ${ARCHIVE_DIR}/spectra
# 3. 将内部类符号"$"替换为"."（如A$B → A.B，与Java源码类名格式一致）
sed -i 's/\$/./g' ${ARCHIVE_DIR}/spectra 

# ============================== 验证测试结果一致性 ==============================
# 验证目的：确保GZOLTAR执行的失败测试用例与Defects4J定义的触发测试用例一致
# 1. 提取Defects4J的触发测试用例（去掉前缀"--- "，排序后保存）
grep "^--- " ${D4J_HOME}/framework/projects/${PID}/trigger_tests/${BID} | sed 's/^--- //' | sort > ${PROJECT_DIR}/d4j_tests_tmp
# 2. 提取GZOLTAR执行的失败测试用例（格式转换：#→::，排序后保存）
grep -w "FAIL" ${ARCHIVE_DIR}/tests | awk -F ',' '{print $1}' | sed 's/#/::/' | sort >  ${PROJECT_DIR}/gzoltar_tests_tmp
# 3. 对比两个测试用例列表，检查差异
DIFF_INFO=$(diff ${PROJECT_DIR}/d4j_tests_tmp  ${PROJECT_DIR}/gzoltar_tests_tmp)
# 若存在差异，将差异信息写入日志文件（用于后续问题排查）
if [[ -n ${DIFF_INFO} ]]; then
	echo -e "${PID}-${BID}:\n${DIFF_INFO}" >> /root/locate_result/exec_info_trigger/${PID}/log
fi

# ============================== 清理临时文件 ==============================
# 删除缺陷项目工作目录（临时文件，已归档关键数据，无需保留）
# rm -rf ${PROJECT_DIR}