#!/bin/bash
# 手动编译Mockito测试

PID=$1
BID=$2
PROJECT_DIR=/tmp/${PID}_${BID}_bug

defects4j checkout -p ${PID} -v ${BID}b -w ${PROJECT_DIR}
cd ${PROJECT_DIR}

echo "=== 手动编译测试 ==="

# 获取依赖和配置
LIB_DIR=$(defects4j export -p cp.test)
SRC_DIR=${PROJECT_DIR}/$(defects4j export -p dir.bin.classes)
TEST_SRC_DIR="./test"  # Mockito的测试源码目录
TEST_CLASSES_DIR="${PROJECT_DIR}/target/test-classes"  # Defects4J期望的目录

# 创建目录
mkdir -p ${TEST_CLASSES_DIR}

echo "源码目录: ${SRC_DIR}"
echo "测试源码目录: ${TEST_SRC_DIR}"
echo "测试类目录: ${TEST_CLASSES_DIR}"

# 查找所有测试Java文件
echo "查找测试文件..."
find ${TEST_SRC_DIR} -name "*.java" > test_sources.txt
echo "找到的测试文件数: $(wc -l < test_sources.txt)"

# 编译测试
echo "编译测试类..."
javac -cp "${LIB_DIR}:${SRC_DIR}" -d ${TEST_CLASSES_DIR} @test_sources.txt

# 检查编译结果
echo "编译结果:"
find ${TEST_CLASSES_DIR} -name "*.class" | wc -l

# 更新Defects4J的测试目录指向
echo "更新测试目录..."
export TEST_DIR=${TEST_CLASSES_DIR}

# 继续GZOLTAR流程
echo "=== 继续GZOLTAR流程 ==="

# 获取测试列表
defects4j export -p tests.all > all_tests.txt
defects4j export -p tests.relevant > relevant_tests.txt

# 创建GZOLTAR测试方法列表
if [[ -s relevant_tests.txt ]]; then
    cp relevant_tests.txt listTestMethods.txt
else
    cp all_tests.txt listTestMethods.txt
fi

sed -i 's/::/#/g' listTestMethods.txt

echo "测试方法数: $(wc -l < listTestMethods.txt)"
head -5 listTestMethods.txt

# 运行GZOLTAR
SER_FILE=${PROJECT_DIR}/gzoltar.ser

# 加载类配置
LOADED_CLASSES_FILE=${D4J_HOME}/framework/projects/${PID}/loaded_classes/${BID}.src
if [[ -f ${LOADED_CLASSES_FILE} && -s ${LOADED_CLASSES_FILE} ]]; then
    NORMAL_CLASSES=$(cat ${LOADED_CLASSES_FILE} | sed 's/$/:/' | tr -d '\n')
    INNER_CLASSES=$(cat ${LOADED_CLASSES_FILE} | sed 's/$/$*:/' | tr -d '\n')
    LOADED_CLASSES=${NORMAL_CLASSES}${INNER_CLASSES}
else
    LOADED_CLASSES="*"
fi

echo "执行GZOLTAR..."
java -javaagent:${GZOLTAR_AGENT_JAR}=destfile=${SER_FILE},buildlocation=${SRC_DIR},includes=${LOADED_CLASSES},excludes="",inclnolocationclasses=false,output="file" \
  -cp ${GZOLTAR_CLI_JAR}:${LIB_DIR} \
  com.gzoltar.cli.Main runTestMethods \
  --testMethods ${PROJECT_DIR}/listTestMethods.txt \
  --collectCoverage

if [[ -f ${SER_FILE} ]]; then
    echo "✓ 覆盖率收集成功"
    
    # 生成故障定位报告
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
        
    # 归档结果
    ARCHIVE_DIR=/root/locate_result/exec_info_relevant/${PID}/${BID}
    mkdir -p ${ARCHIVE_DIR}
    
    if [[ -f ${PROJECT_DIR}/sfl/txt/ochiai.ranking.csv ]]; then
        cp ${PROJECT_DIR}/sfl/txt/ochiai.ranking.csv ${ARCHIVE_DIR}/
        echo "✓ 故障定位报告生成成功"
        echo "前5个可疑方法:"
        head -5 ${ARCHIVE_DIR}/ochiai.ranking.csv
    fi
else
    echo "✗ 覆盖率收集失败"
fi