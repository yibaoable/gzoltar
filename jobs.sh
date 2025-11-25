#!/bin/bash
# 从txt文件读取项目-缺陷ID列表，并行执行GZOLTAR脚本

# 配置参数
INPUT_FILE="/root/succ_bug_id.txt"          # 包含所有数据的txt文件路径
SCRIPT_PATH="/root/gzoltar/job_tri.sh"          # GZOLTAR执行脚本路径
LOG_FILE="/root/locate_result/batch_parallel_trigger.log"  # 批量执行日志
SKIP_EXISTED=false                           # 是否跳过已执行完成的缺陷（true=跳过，false=覆盖）
MAX_PARALLEL=5                             # 最大并发数（根据服务器性能调整，建议2-10）
CURRENT_PARALLEL=0                          # 当前并发数计数器

# 检查输入文件是否存在
if [ ! -f ${INPUT_FILE} ]; then
  echo "错误：找不到输入文件 ${INPUT_FILE}，请检查路径是否正确"
  exit 1
fi

# 检查原有脚本是否存在
if [ ! -f ${SCRIPT_PATH} ]; then
  echo "错误：找不到脚本 ${SCRIPT_PATH}，请检查路径是否正确"
  exit 1
fi

# 初始化日志文件
echo "===== 并行批量执行开始：$(date) =====" > ${LOG_FILE}
echo "输入文件：${INPUT_FILE}" >> ${LOG_FILE}
echo "是否跳过已执行：${SKIP_EXISTED}" >> ${LOG_FILE}
echo "最大并发数：${MAX_PARALLEL}" >> ${LOG_FILE}
echo "=================================" >> ${LOG_FILE}

# 定义并行执行的函数（每个任务独立运行）
execute_task() {
  local PID=$1
  local BID=$2
  local TASK_LOG="/root/locate_result/logs_trigger/task_${PID}_${BID}.log"  # 单个任务的独立日志

  # 输出任务开始信息
  echo "▶️  启动任务：${PID}-${BID}（后台运行，日志：${TASK_LOG}）"
  echo -e "\n===== 任务 ${PID}-${BID} 开始：$(date) =====" >> ${LOG_FILE}
  echo "任务日志文件：${TASK_LOG}" >> ${LOG_FILE}

  # 执行脚本（输出重定向到单个任务日志）
  ${SCRIPT_PATH} ${PID} ${BID} > ${TASK_LOG} 2>&1

  # 检查执行结果
  if [ $? -eq 0 ]; then
    echo "✅ 任务完成：${PID}-${BID}（成功）"
    echo "状态：成功" >> ${LOG_FILE}
  else
    echo "❌ 任务完成：${PID}-${BID}（失败，详情见 ${TASK_LOG}）"
    echo "状态：失败（详情见任务日志）" >> ${LOG_FILE}
  fi
  echo "===== 任务 ${PID}-${BID} 结束：$(date) =====" >> ${LOG_FILE}
}

# 读取txt文件每一行，循环创建并行任务
while IFS= read -r LINE; do
  # 跳过空行和注释行（以#开头）
  if [ -z "${LINE}" ] || [[ "${LINE}" =~ ^# ]]; then
    continue
  fi

  # 拆分项目ID（PID）和缺陷ID（BID）：按"-"分割（如JacksonCore-11 → PID=JacksonCore，BID=11）
  PID=$(echo ${LINE} | awk -F '-' '{print $1}')
  BID=$(echo ${LINE} | awk -F '-' '{print $2}')

  # 验证格式是否正确（必须包含"-"且BID为数字）
  if [ -z "${PID}" ] || [ -z "${BID}" ] || ! [[ "${BID}" =~ ^[0-9]+$ ]]; then
    echo "❌ 格式错误：${LINE}（正确格式如JacksonCore-11），跳过"
    echo "格式错误：${LINE} → 跳过" >> ${LOG_FILE}
    continue
  fi

  # 若配置跳过已执行，检查结果目录是否存在
  ARCHIVE_DIR="/root/locate_result/exec_info_trigger/${PID}/${BID}"
  if [ "${SKIP_EXISTED}" = true ] && [ -d ${ARCHIVE_DIR} ] && [ -f ${ARCHIVE_DIR}/ranking.csv ]; then
    echo "⚠️ ${PID}-${BID} 已执行完成，跳过"
    echo "已跳过：${PID}-${BID}（已存在结果）" >> ${LOG_FILE}
    continue
  fi

  # 控制并发数：如果达到最大并发，等待任意后台任务完成
  if [ ${CURRENT_PARALLEL} -ge ${MAX_PARALLEL} ]; then
    wait -n  # 等待任意一个后台进程结束
    CURRENT_PARALLEL=$((CURRENT_PARALLEL - 1))
  fi

  # 启动后台任务
  execute_task ${PID} ${BID} &
  CURRENT_PARALLEL=$((CURRENT_PARALLEL + 1))
done < ${INPUT_FILE}

# 等待所有剩余的后台任务完成
echo -e "\n===== 所有任务已启动，等待剩余任务完成... ====="
wait
CURRENT_PARALLEL=0

# 输出执行总结
echo -e "\n===== 并行批量执行全部结束：$(date) =====" >> ${LOG_FILE}
echo "批量执行完成！"
echo "主日志文件：${LOG_FILE}"
echo "单个任务日志：/root/locate_result/logs_trigger/task_*.log"
echo "结果归档目录：/root/locate_result/exec_info_trigger/"