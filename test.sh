#!/bin/bash
# 脚本功能：自动化处理Defects4J缺陷项目，使用GZOLTAR工具收集代码覆盖率并生成故障定位报告

# ============================== 基础变量定义 ==============================
SCRIPT_DIR=$(pwd)
PID=$1
BID=$2
PROJECT_DIR=/tmp/${PID}_${BID}_bug

# ============================== 检出Defects4J项目 ==============================
defects4j checkout -p ${PID} -v ${BID}b -w ${PROJECT_DIR}
cd ${PROJECT_DIR}
defects4j compile

# 导出项目关键目录路径
SRC_DIR=${PROJECT_DIR}/$(defects4j export -p dir.bin.classes)
TEST_DIR=${PROJECT_DIR}/$(defects4j export -p dir.bin.tests)
LIB_DIR=$(defects4j export -p cp.test)

echo "=== 调试信息 ==="
echo "SRC_DIR: ${SRC_DIR}"
echo "TEST_DIR: ${TEST_DIR}"
echo "LIB_DIR: ${LIB_DIR}"

# ============================== 检查测试目录内容 ==============================
echo -e "\n=== 检查测试目录结构 ==="
find ${TEST_DIR} -name "*.class" | head -20 | while read file; do
    echo "测试类: $file"
    # 尝试反编译查看方法信息
    class_name=$(basename "$file" .class)
    echo "  类名: $class_name"
done

# ============================== 分析相关测试用例文件 ==============================
RELEVANT_TESTS_FILE=${D4J_HOME}/framework/projects/${PID}/relevant_tests/${BID}
TRIGGER_TESTS_FILE=${D4J_HOME}/framework/projects/${PID}/trigger_tests/${BID}

echo -e "\n=== 分析相关测试用例 ==="
echo "relevant_tests文件前10行:"
head -10 ${RELEVANT_TESTS_FILE}

echo -e "\ntrigger_tests文件前10行:"
head -10 ${TRIGGER_TESTS_FILE}

# 提取测试类名（去除方法部分）
echo -e "\n=== 提取测试类名 ==="
RELEVANT_CLASSES=$(cat ${RELEVANT_TESTS_FILE} | sed 's/#.*//' | sort | uniq)
echo "相关测试类:"
echo "${RELEVANT_CLASSES}"

# 检查这些类是否在测试目录中存在
echo -e "\n=== 检查测试类是否存在 ==="
for class in ${RELEVANT_CLASSES}; do
    # 将包路径转换为文件路径
    class_file="${TEST_DIR}/$(echo ${class} | sed 's/\./\//g').class"
    if [[ -f "${class_file}" ]]; then
        echo "✓ 找到: ${class_file}"
    else
        echo "✗ 缺失: ${class_file}"
        # 尝试查找类似的文件
        find ${TEST_DIR} -name "*${class##*.}.class" | head -3 | while read found; do
            echo "  可能匹配: $found"
        done
    fi
done

# ============================== 构建测试包含规则 ==============================
echo -e "\n=== 构建测试包含规则 ==="

# 方法1：使用原始的相关测试用例（带方法名）
RELEVANT_TESTS_ORIGINAL=$(cat ${RELEVANT_TESTS_FILE} | sed 's/$/#*/' | sed ':a;N;$!ba;s/\n/:/g')
echo "原始RELEVANT_TESTS（前200字符）:"
echo "${RELEVANT_TESTS_ORIGINAL:0:200}..."

# 方法2：只使用类名（更宽松的匹配）
RELEVANT_CLASSES_PATTERN=$(echo "${RELEVANT_CLASSES}" | sed 's/$/::*/' | sed ':a;N;$!ba;s/\n/:/g')
echo "类级别RELEVANT_TESTS（前200字符）:"
echo "${RELEVANT_CLASSES_PATTERN:0:200}..."

# ============================== 尝试多种方法列出测试 ==============================

# 尝试1：使用原始方法
echo -e "\n=== 尝试1：使用原始相关测试用例 ==="
java -cp ${LIB_DIR}:${GZOLTAR_CLI_JAR} \
  com.gzoltar.cli.Main listTestMethods \
  ${TEST_DIR} \
  --outputFile ${PROJECT_DIR}/listTestMethods_original.txt \
  --includes "${RELEVANT_TESTS_ORIGINAL}"

echo "原始方法结果:"
cat ${PROJECT_DIR}/listTestMethods_original.txt
echo "行数: $(wc -l < ${PROJECT_DIR}/listTestMethods_original.txt)"

# 尝试2：使用类级别匹配
echo -e "\n=== 尝试2：使用类级别匹配 ==="
java -cp ${LIB_DIR}:${GZOLTAR_CLI_JAR} \
  com.gzoltar.cli.Main listTestMethods \
  ${TEST_DIR} \
  --outputFile ${PROJECT_DIR}/listTestMethods_classlevel.txt \
  --includes "${RELEVANT_CLASSES_PATTERN}"

echo "类级别匹配结果:"
cat ${PROJECT_DIR}/listTestMethods_classlevel.txt
echo "行数: $(wc -l < ${PROJECT_DIR}/listTestMethods_classlevel.txt)"

# 尝试3：不使用includes参数（获取所有测试）
echo -e "\n=== 尝试3：获取所有测试方法 ==="
java -cp ${LIB_DIR}:${GZOLTAR_CLI_JAR} \
  com.gzoltar.cli.Main listTestMethods \
  ${TEST_DIR} \
  --outputFile ${PROJECT_DIR}/listTestMethods_all.txt

echo "所有测试方法:"
cat ${PROJECT_DIR}/listTestMethods_all.txt | head -20
echo "总行数: $(wc -l < ${PROJECT_DIR}/listTestMethods_all.txt)"

# 选择最合适的结果
if [[ -s ${PROJECT_DIR}/listTestMethods_original.txt ]]; then
    cp ${PROJECT_DIR}/listTestMethods_original.txt ${PROJECT_DIR}/listTestMethods.txt
    echo "使用原始方法结果"
elif [[ -s ${PROJECT_DIR}/listTestMethods_classlevel.txt ]]; then
    cp ${PROJECT_DIR}/listTestMethods_classlevel.txt ${PROJECT_DIR}/listTestMethods.txt
    echo "使用类级别匹配结果"
else
    cp ${PROJECT_DIR}/listTestMethods_all.txt ${PROJECT_DIR}/listTestMethods.txt
    echo "使用所有测试方法"
fi

echo -e "\n最终使用的测试方法文件:"
cat ${PROJECT_DIR}/listTestMethods.txt | head -10
echo "总测试方法数: $(wc -l < ${PROJECT_DIR}/listTestMethods.txt)"

# ============================== 检查GZOLTAR代理配置 ==============================
echo -e "\n=== 检查GZOLTAR配置 ==="
echo "GZOLTAR_CLI_JAR: ${GZOLTAR_CLI_JAR}"
echo "GZOLTAR_AGENT_JAR: ${GZOLTAR_AGENT_JAR}"
ls -la ${GZOLTAR_CLI_JAR} ${GZOLTAR_AGENT_JAR}

# ============================== 定义覆盖率收集范围 ==============================
SER_FILE=${PROJECT_DIR}/gzoltar.ser
LOADED_CLASSES_FILE=${D4J_HOME}/framework/projects/${PID}/loaded_classes/${BID}.src

if [[ -f ${LOADED_CLASSES_FILE} && -s ${LOADED_CLASSES_FILE} ]]; then
    NORMAL_CLASSES=$(cat ${LOADED_CLASSES_FILE} | sed 's/$/:/' | sed ':a;N;$!ba;s/\n//g')
    INNER_CLASSES=$(cat ${LOADED_CLASSES_FILE} | sed 's/$/$*:/' | sed ':a;N;$!ba;s/\n//g')
    LOADED_CLASSES=${NORMAL_CLASSES}${INNER_CLASSES}
else
    echo "使用默认包含所有类"
    LOADED_CLASSES="*"
fi

# ============================== 执行测试并收集覆盖率 ==============================
if [[ -s ${PROJECT_DIR}/listTestMethods.txt ]]; then
    echo -e "\n=== 执行测试并收集覆盖率 ==="
    java -javaagent:${GZOLTAR_AGENT_JAR}=destfile=${SER_FILE},buildlocation=${SRC_DIR},includes=${LOADED_CLASSES},excludes="",inclnolocationclasses=false,output="file" \
      -cp ${GZOLTAR_CLI_JAR}:${LIB_DIR} \
      com.gzoltar.cli.Main runTestMethods \
      --testMethods ${PROJECT_DIR}/listTestMethods.txt \
      --collectCoverage

    echo "覆盖率文件状态:"
    ls -la ${SER_FILE} 2>/dev/null || echo "覆盖率文件未生成"
else
    echo "错误：没有可执行的测试方法"
    exit 1
fi

# ============================== 生成故障定位报告 ==============================
if [[ -f ${SER_FILE} ]]; then
    echo -e "\n=== 生成故障定位报告 ==="
    java -cp ${GZOLTAR_CLI_JAR}:${LIB_DIR} \
      com.gzoltar.cli.Main faultLocalizationReport \
        --buildLocation ${SRC_DIR} \
        --granularity method \
        --inclPublicMethods \
        --inclStaticConstructors \
        --inclDeprecatedMethods \
        --dataFile ${SER_FILE} \
        --outputDirectory ${PROJECT_DIR} \
        --family sfl \
        --formula ochiai \
        --metric entropy \
        --formatter txt

    # 检查生成的文件
    echo -e "\n=== 生成的报告文件 ==="
    find ${PROJECT_DIR}/sfl -type f 2>/dev/null | while read file; do
        echo "文件: $file"
        head -5 "$file" 2>/dev/null | while read line; do
            echo "  $line"
        done
    done
else
    echo "错误：覆盖率文件未生成，无法生成故障定位报告"
fi

# ============================== 关键文件归档 ==============================
# 其余代码保持不变...
ARCHIVE_DIR=/root/locate_result/exec_info_relevant/${PID}/${BID}
mkdir -p ${ARCHIVE_DIR}

if [[ -f ${PROJECT_DIR}/sfl/txt/ochiai.ranking.csv ]]; then
    RANKING_FILE=${PROJECT_DIR}/sfl/txt/ochiai.ranking.csv
    MATRIX_FILE=${PROJECT_DIR}/sfl/txt/matrix.txt
    SPECTRA_FILE=${PROJECT_DIR}/sfl/txt/spectra.csv
    TESTS_FILE=${PROJECT_DIR}/sfl/txt/tests.csv

    mv ${MATRIX_FILE} ${ARCHIVE_DIR}/matrix 2>/dev/null || echo "matrix.txt不存在"
    mv ${RANKING_FILE} ${ARCHIVE_DIR}/ranking.csv 2>/dev/null || echo "ranking.csv不存在"
    
    if [[ -f ${SPECTRA_FILE} ]]; then
        tail -n +2 ${SPECTRA_FILE} > ${ARCHIVE_DIR}/spectra
        sed -i -E 's/(\$\w+)\$.*#/\1#/g' ${ARCHIVE_DIR}/spectra
        sed -i 's/#.*:/#/g' ${ARCHIVE_DIR}/spectra
        sed -i 's/\$/./g' ${ARCHIVE_DIR}/spectra
    fi
    
    if [[ -f ${TESTS_FILE} ]]; then
        tail -n +2 ${TESTS_FILE} > ${ARCHIVE_DIR}/tests
    fi
    
    echo "文件已归档到: ${ARCHIVE_DIR}"
    ls -la ${ARCHIVE_DIR}
fi