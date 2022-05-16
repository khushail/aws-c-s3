#!/usr/bin/env bash

export USER_NAME=$1
export SHOW_INSTANCE_DASHBOARD_SCRIPT=$2
export RUN_PROJECT_TEMPLATE=$3
export PROJECT_NAME=$4
export BRANCH_NAME=$5
export THROUGHPUT_GBPS=$6
export PROJECT_SHELL_SCRIPT=$7
export INSTANCE_TYPE=$8
export REGION=$9
export RUN_COMMAND=${10}
export CFN_NAME=${11}
export P90_SCRIPT=${12}
# TODO the auto tear down should be a flag that makes more sense
export AUTO_TEAR_DOWN=${13:-1}

export TEST_OBJECT_NAME=crt-canary-obj-multipart
export RUN_PROJECT_LOG_FN=/tmp/benchmark.log
export PUBLISH_METRICS_LOG_FN=/tmp/publish_metrics.log
export SHOW_INSTANCE_DASHBOARD_USER_DEST=/home/$USER_NAME/show_instance_dashboard.sh
export PERF_SCRIPT_TEMP=/tmp/perf_script_temp.tmp
export DOWNLOAD_PERF_SCRIPT=/home/$USER_NAME/download_performance.sh
export UPLOAD_PERF_SCRIPT=/home/$USER_NAME/upload_performance.sh
export USER_DIR=/home/$USER_NAME/
export S3_BUCKET_NAME=automatic-canary-test-bucket-tmp

function publish_bytes_in_metric() {

    aws cloudwatch put-metric-data \
        --no-cli-pager \
        --namespace S3Benchmark \
        --metric-name BytesIn \
        --unit Bytes \
        --dimensions Project=$PROJECT_NAME,Branch=$BRANCH_NAME,InstanceType=$INSTANCE_TYPE \
        --storage-resolution 1 \
        --value $3 >> $PUBLISH_METRICS_LOG_FN
    # Store the value to a temp file
    echo $3 >> "/tmp/${@: -1}_BytesIn.txt"
}

function publish_bytes_out_metric() {

    aws cloudwatch put-metric-data \
        --no-cli-pager \
        --namespace S3Benchmark \
        --metric-name BytesOut \
        --unit Bytes \
        --dimensions Project=$PROJECT_NAME,Branch=$BRANCH_NAME,InstanceType=$INSTANCE_TYPE \
        --storage-resolution 1 \
        --value $2 >> $PUBLISH_METRICS_LOG_FN
    # Store the value to a temp file
    echo $2 >> "/tmp/${@: -1}_BytesOut.txt"
}

export -f publish_bytes_in_metric
export -f publish_bytes_out_metric

sudo yum update -y
sudo yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
sudo yum-config-manager --enable epel

sudo yum install -y tmux bwm-ng htop

sudo chmod +x $SHOW_INSTANCE_DASHBOARD_SCRIPT
cp $SHOW_INSTANCE_DASHBOARD_SCRIPT $SHOW_INSTANCE_DASHBOARD_USER_DEST

sudo yum install -y cmake3 git gcc clang

sudo alternatives --install /usr/bin/cmake cmake /usr/bin/cmake3 100 \
    --slave /usr/bin/ctest ctest /usr/bin/ctest3 \
    --slave /usr/bin/cpack cpack /usr/bin/cpack3 \
    --slave /usr/bin/ccmake ccmake /usr/bin/ccmake3

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws
rm -rf awscliv2.zip

# create a temp bucket for test
aws s3 mb s3://$S3_BUCKET_NAME --region $REGION

pip3 install numpy

INSTANCE_ID=`curl http://169.254.169.254/latest/meta-data/instance-id`
aws ec2 monitor-instances --instance-ids $INSTANCE_ID

sudo sysctl kernel.perf_event_paranoid=0

sudo mkdir /home/$USER_NAME/

sudo chmod +x $PROJECT_SHELL_SCRIPT
${PROJECT_SHELL_SCRIPT} 'SETUP'

AWK_SCRIPT="{"
AWK_SCRIPT="$AWK_SCRIPT sub(\"{PROJECT_NAME}\", \"$PROJECT_NAME\");";
AWK_SCRIPT="$AWK_SCRIPT sub(\"{PROJECT_SHELL_SCRIPT}\", \"$PROJECT_SHELL_SCRIPT\");"
AWK_SCRIPT="$AWK_SCRIPT sub(\"{BRANCH_NAME}\", \"$BRANCH_NAME\");"
AWK_SCRIPT="$AWK_SCRIPT sub(\"{THROUGHPUT_GBPS}\", \"$THROUGHPUT_GBPS\");"
AWK_SCRIPT="$AWK_SCRIPT sub(\"{INSTANCE_TYPE}\", \"$INSTANCE_TYPE\");"
AWK_SCRIPT="$AWK_SCRIPT sub(\"{REGION}\", \"$REGION\");"
AWK_SCRIPT="$AWK_SCRIPT sub(\"{USER_NAME}\", \"$USER_NAME\");"
AWK_SCRIPT="$AWK_SCRIPT sub(\"{RUN_PROJECT_LOG_FN}\", \"$RUN_PROJECT_LOG_FN\");"
AWK_SCRIPT="$AWK_SCRIPT sub(\"{PUBLISH_METRICS_LOG_FN}\", \"$PUBLISH_METRICS_LOG_FN\");"
AWK_SCRIPT="$AWK_SCRIPT sub(\"{TEST_OBJECT_NAME}\", \"$TEST_OBJECT_NAME\");"
AWK_SCRIPT="$AWK_SCRIPT sub(\"{S3_BUCKET_NAME}\", \"$S3_BUCKET_NAME\");"
AWK_SCRIPT="$AWK_SCRIPT print}"

awk "$AWK_SCRIPT" $RUN_PROJECT_TEMPLATE > $PERF_SCRIPT_TEMP
awk "{sub(\"{RUN_COMMAND}\", \"DOWNLOAD_PERFORMANCE\"); print}" $PERF_SCRIPT_TEMP > $DOWNLOAD_PERF_SCRIPT
awk "{sub(\"{RUN_COMMAND}\", \"UPLOAD_PERFORMANCE\"); print}" $PERF_SCRIPT_TEMP > $UPLOAD_PERF_SCRIPT

sudo chmod +x $DOWNLOAD_PERF_SCRIPT
sudo chmod +x $UPLOAD_PERF_SCRIPT

CURRENT_TIME=`date +"%Y-%m-%d:%H"`

if [ $RUN_COMMAND = "DOWNLOAD_PERFORMANCE" ]; then
    truncate -s 5G $TEST_OBJECT_NAME
    aws s3 cp $TEST_OBJECT_NAME s3://$S3_BUCKET_NAME
    stdbuf -i0 -o0 -e0 bwm-ng -I eth0 -o csv -u bits -d -c 0 \
        | stdbuf -o0 grep -v total \
        | stdbuf -o0 cut -f1,3,4 -d\; --output-delimiter=' ' \
        | xargs -n3 -t -P 32 bash -c 'publish_bytes_in_metric "$@" '\"${CURRENT_TIME}\"'' _ &

    sudo $DOWNLOAD_PERF_SCRIPT
elif [ $RUN_COMMAND = "UPLOAD_PERFORMANCE" ]; then
    stdbuf -i0 -o0 -e0 bwm-ng -I eth0 -o csv -u bits -d -c 0 \
        | stdbuf -o0 grep -v total \
        | stdbuf -o0 cut -f1,3,4 -d\; --output-delimiter=' ' \
        | xargs -n3 -t -P 32 bash -c 'publish_bytes_out_metric "$@" '\"${CURRENT_TIME}\"'' _ &

    sudo $UPLOAD_PERF_SCRIPT
fi

# Store the data to an S3 bucket for future refrence.
aws s3 cp "/tmp/${CURRENT_TIME}_BytesIn.txt"  "s3://s3-canary-logs/${PROJECT_NAME}_${BRANCH_NAME}/${CURRENT_TIME}_${INSTANCE_TYPE}/"
aws s3 cp "/tmp/${CURRENT_TIME}_BytesOut.txt"  "s3://s3-canary-logs/${PROJECT_NAME}_${BRANCH_NAME}/${CURRENT_TIME}_${INSTANCE_TYPE}/"

python3 $P90_SCRIPT "/tmp/${CURRENT_TIME}_BytesIn.txt" "/tmp/${CURRENT_TIME}_BytesOut.txt" $PROJECT_NAME $BRANCH_NAME $INSTANCE_TYPE

# delete the tempary bucket
aws s3 rb s3://$S3_BUCKET_NAME --force

# if [ $AUTO_TEAR_DOWN = 1 ]; then
#     aws lambda invoke \
#         --cli-binary-format raw-in-base64-out \
#         --function-name BenchmarkManager \
#         --invocation-type Event \
#         --payload '{ "action": "delete", "stack_name": '\"${CFN_NAME}\"' }' \
#         response.json
# fi
