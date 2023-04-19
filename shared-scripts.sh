#!/bin/bash

# set exit on error to true
set -e

# We have custom caching for our CodeBuild pipelines
# which allows us to share caches with jobs in the same batch

# storeCache <local path> <cache location>
function storeCache {
    localPath="$1"
    alias="$2"
    s3Path="s3://$CACHE_BUCKET_NAME/$CODEBUILD_SOURCE_VERSION/$alias"
    echo writing cache to $s3Path
    # zip contents and upload to s3
    if ! (cd $localPath && tar cz . | aws s3 cp - $s3Path); then
        echo Something went wrong storing the cache.
    fi
    echo done writing cache
    cd $CODEBUILD_SRC_DIR
}
function storeCacheFile {
    localFilePath="$1"
    alias="$2"
    s3Path="s3://$CACHE_BUCKET_NAME/$CODEBUILD_SOURCE_VERSION/$alias"
    echo writing cache to $s3Path
    # zip contents and upload to s3
    if ! (aws s3 cp $localFilePath $s3Path); then
        echo Something went wrong storing the cache.
    fi
    echo done writing cache
    cd $CODEBUILD_SRC_DIR
}
# loadCache <cache location> <local path>
function loadCache {
    alias="$1"
    localPath="$2"
    s3Path="s3://$CACHE_BUCKET_NAME/$CODEBUILD_SOURCE_VERSION/$alias"
    echo loading cache from $s3Path
    # create directory if it doesn't exist yet
    mkdir -p $localPath
    # check if cache exists in s3
    if ! aws s3 ls $s3Path > /dev/null; then
        echo "Cache not found."
        exit 0
    fi
    # load cache and unzip it
    if ! (cd $localPath && aws s3 cp $s3Path - | tar xz); then
        echo "Something went wrong fetching the cache. Continuing anyway."
    fi
    echo done loading cache
    cd $CODEBUILD_SRC_DIR
}
function loadCacheFile {
    alias="$1"
    localFilePath="$2"
    s3Path="s3://$CACHE_BUCKET_NAME/$CODEBUILD_SOURCE_VERSION/$alias"
    echo loading cache file from $s3Path
    # check if cache file exists in s3
    if ! aws s3 ls $s3Path > /dev/null; then
        echo "Cache file not found."
        exit 0
    fi
    # load cache file
    if ! (aws s3 cp $s3Path $localFilePath); then
        echo "Something went wrong fetching the cache file. Continuing anyway."
    fi
    echo done loading cache
    cd $CODEBUILD_SRC_DIR
}
function _loadTestAccountCredentials {
    echo ASSUMING PARENT TEST ACCOUNT credentials
    echo $TEST_ACCOUNT_ROLE
    echo $RANDOM

    session_id=$((1 + $RANDOM % 10000))
    creds=$(aws sts assume-role --role-arn $TEST_ACCOUNT_ROLE --role-session-name testSession${session_id} --duration-seconds 3600)
    if [ -z $(echo $creds | jq -c -r '.AssumedRoleUser.Arn') ]; then
        echo "Unable to assume parent e2e account role."
        return
    fi
    echo "Using account credentials for $(echo $creds | jq -c -r '.AssumedRoleUser.Arn')"
    export AWS_ACCESS_KEY_ID=$(echo $creds | jq -c -r ".Credentials.AccessKeyId")
    export AWS_SECRET_ACCESS_KEY=$(echo $creds | jq -c -r ".Credentials.SecretAccessKey")
    export AWS_SESSION_TOKEN=$(echo $creds | jq -c -r ".Credentials.SessionToken")
}
function _setShell {
    echo Setting Shell
    yarn config set script-shell $(which bash)
}
function _buildLinux {
    _setShell
    echo Linux Build
    
    yarn run production-build
    yarn build-tests

    storeCache $CODEBUILD_SRC_DIR repo
    storeCache $HOME/.cache .cache
}
function _buildWindows {
    _setShell
    echo Windows Build
    yarn run production-build
    yarn build-tests
    storeCache $CODEBUILD_SRC_DIR repo-windows
    storeCache $HOME/.cache .cache-windows
}
function _unitTests {
    FAILED_TEST_REGEX_FILE=./amplify-unit-tests/failed_unit_tests.txt
    if [ -f  $FAILED_TEST_REGEX_FILE ]; then
        # read the content of failed tests
        failedTests=$(<$FAILED_TEST_REGEX_FILE)
        yarn test-ci --forceExit --no-cache --maxWorkers=4 $TEST_SUITE -t "$failedTests"
    else
        yarn test-ci --forceExit --no-cache --maxWorkers=4 $TEST_SUITE
    fi
}
function _testLinux {
    echo Run Test

    # download [repo, .cache from s3]
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache

    # node --expose-gc node_modules/.bin/jest --logHeapUsage
    yarn test-ci

    # yarn test-ci-1
    # yarn test-ci-2

    # echo collecting coverage
    # yarn coverage
}
function _validateCDKVersion {
    echo Validate CDK Version
    # download [repo, .cache from s3]
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache
    yarn ts-node .circleci/validate_cdk_version.ts
}
function _lint {
    echo Linting
    # download [repo, .cache from s3]
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache

    yarn lint-check
    yarn lint-check-package-json
    yarn prettier-check
}
function _verifyAPIExtract {
    echo Verify API Extract
    # download [repo, .cache from s3]
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache
    yarn verify-api-extract
}
function _verifyYarnLock {
    echo "Verify Yarn Lock"
    # download [repo, .cache from s3]
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache
    yarn verify-yarn-lock
}
function _verifyVersionsMatch {
    echo Verify Versions Match
    # download [repo, .cache, verdaccio-cache from s3]
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache
    loadCache verdaccio-cache $CODEBUILD_SRC_DIR/../verdaccio-cache
    
    source .circleci/local_publish_helpers.sh && startLocalRegistry "$CODEBUILD_SRC_DIR/.circleci/verdaccio.yaml"
    setNpmRegistryUrlToLocal
    changeNpmGlobalPath
    checkPackageVersionsInLocalNpmRegistry
}
function _mockE2ETests {
    # download [repo, .cache from s3]
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache

    sudo apt-get -y install lsof

    source .circleci/local_publish_helpers.sh
    cd packages/amplify-util-mock/

    yarn e2e
}
function _publishToLocalRegistry {
    echo "Publish To Local Registry"
    # download [repo, .cache from s3]
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache

    source ./.circleci/local_publish_helpers.sh && startLocalRegistry "$CODEBUILD_SRC_DIR/.circleci/verdaccio.yaml"
    setNpmRegistryUrlToLocal
    export LOCAL_PUBLISH_TO_LATEST=true
    ./.circleci/publish-codebuild.sh
    unsetNpmRegistryUrl

    echo Generate Change Log
    git reset --soft HEAD~1
    yarn ts-node scripts/unified-changelog.ts
    cat UNIFIED_CHANGELOG.md
    
    echo Save new amplify Github tag
    node scripts/echo-current-cli-version.js > .amplify-pkg-version
    
    echo LS HOME
    ls $CODEBUILD_SRC_DIR/..

    echo LS REPO
    ls $CODEBUILD_SRC_DIR

    # copy [verdaccio-cache, changelog, pkgtag to s3]
    storeCache $CODEBUILD_SRC_DIR/../verdaccio-cache verdaccio-cache

    storeCacheFile $CODEBUILD_SRC_DIR/UNIFIED_CHANGELOG.md UNIFIED_CHANGELOG.md
    storeCacheFile $CODEBUILD_SRC_DIR/.amplify-pkg-version .amplify-pkg-version
}
function _uploadPkgBinaries {
    echo Consolidate binaries cache and upload

    loadCache repo $CODEBUILD_SRC_DIR
    loadCache repo-out-arm $CODEBUILD_SRC_DIR/out
    loadCache repo-out-linux $CODEBUILD_SRC_DIR/out
    loadCache repo-out-macos $CODEBUILD_SRC_DIR/out
    loadCache repo-out-win $CODEBUILD_SRC_DIR/out

    echo Done loading binaries
    ls $CODEBUILD_SRC_DIR/out

    # source .circleci/local_publish_helpers.sh
    # uploadPkgCli

    storeCache $CODEBUILD_SRC_DIR/out all-binaries
}
function _buildBinaries {
    echo Start verdaccio and package CLI
    binaryType="$1"
    # download [repo, yarn, verdaccio from s3]
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache
    loadCache verdaccio-cache $CODEBUILD_SRC_DIR/../verdaccio-cache

    loadCacheFile .amplify-pkg-version $CODEBUILD_SRC_DIR/.amplify-pkg-version
    loadCacheFile UNIFIED_CHANGELOG.md $CODEBUILD_SRC_DIR/UNIFIED_CHANGELOG.md

    source .circleci/local_publish_helpers.sh
    startLocalRegistry "$CODEBUILD_SRC_DIR/.circleci/verdaccio.yaml"
    setNpmRegistryUrlToLocal
    changeNpmGlobalPath
    generatePkgCli $binaryType
    unsetNpmRegistryUrl

    # copy [repo/out to s3]
    storeCache $CODEBUILD_SRC_DIR/out repo-out-$binaryType
}
function _install_packaged_cli_linux {
    echo INSTALL PACKAGED CLI TO PATH

    cd $CODEBUILD_SRC_DIR/out
    ln -sf amplify-pkg-linux-x64 amplify
    export PATH=$AMPLIFY_DIR:$PATH
    cd $CODEBUILD_SRC_DIR
}
function _install_packaged_cli_win {
    echo Install Amplify Packaged CLI to PATH
    # rename the command to amplify
    cd $CODEBUILD_SRC_DIR/out
    cp amplify-pkg-win-x64.exe amplify.exe

    echo Move to CLI Binary to already existing PATH
    # This is a Hack to make sure the Amplify CLI is in the PATH
    cp $CODEBUILD_SRC_DIR/out/amplify.exe $env:homedrive\$env:homepath\AppData\Local\Microsoft\WindowsApps
}
function _runE2ETestsLinux {
    echo RUN E2E Tests Linux
    
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache
    loadCache verdaccio-cache $CODEBUILD_SRC_DIR/../verdaccio-cache

    loadCache all-binaries $CODEBUILD_SRC_DIR/out
    loadCacheFile .amplify-pkg-version $CODEBUILD_SRC_DIR/.amplify-pkg-version
    loadCacheFile UNIFIED_CHANGELOG.md $CODEBUILD_SRC_DIR/UNIFIED_CHANGELOG.md

    _install_packaged_cli_linux

    # verify installation
    amplify version

    source .circleci/local_publish_helpers.sh && startLocalRegistry "$CODEBUILD_SRC_DIR/.circleci/verdaccio.yaml"
    # source $BASH_ENV

    setNpmRegistryUrlToLocal
    changeNpmGlobalPath
    amplify version
    
    cd packages/amplify-e2e-tests

    _loadTestAccountCredentials

    retry runE2eTest
}
function _runE2ETestsWin {
    echo RUN E2E Tests Windows

    echo Git Enable Long Paths
    git config --global core.longpaths true

    loadCache repo-windows $CODEBUILD_SRC_DIR
    loadCache .cache-windows $HOME/.cache
    loadCache verdaccio-cache $CODEBUILD_SRC_DIR/../verdaccio-cache

    loadCache all-binaries $CODEBUILD_SRC_DIR/out
    loadCacheFile .amplify-pkg-version $CODEBUILD_SRC_DIR/.amplify-pkg-version
    loadCacheFile UNIFIED_CHANGELOG.md $CODEBUILD_SRC_DIR/UNIFIED_CHANGELOG.md

    source .circleci/local_publish_helpers.sh && startLocalRegistry "$CODEBUILD_SRC_DIR/.circleci/verdaccio.yaml"
    source $BASH_ENV

    setNpmRegistryUrlToLocal
    changeNpmGlobalPath
    amplify version
    
    cd packages/amplify-e2e-tests

    _loadTestAccountCredentials

    retry runE2eTest
}
function _runE2ETestsWindows {
    echo RUN E2E Tests Windows

    echo Git Enable Long Paths
    git config --global core.longpaths true

    loadCache repo-windows $CODEBUILD_SRC_DIR
    loadCache .cache-windows $HOME/.cache
    loadCache verdaccio-cache $CODEBUILD_SRC_DIR/../verdaccio-cache

    loadCache all-binaries $CODEBUILD_SRC_DIR/out
    loadCacheFile .amplify-pkg-version $CODEBUILD_SRC_DIR/.amplify-pkg-version
    loadCacheFile UNIFIED_CHANGELOG.md $CODEBUILD_SRC_DIR/UNIFIED_CHANGELOG.md

    echo Rename the Packaged CLI to amplify
    cd $CODEBUILD_SRC_DIR/out
    cp amplify-pkg-win-x64.exe amplify.exe
    
    echo Move CLI Binary to alredy existing PATH
    # This is a Hack to make sure the Amplify CLI is in the PATH
    cp $CODEBUILD_SRC_DIR/out/amplify-pkg-win-x64.exe $env:homedrive\$env:homepath\AppData\Local\Microsoft\WindowsApps\amplify.exe
    _install_packaged_cli_win
    # verify installation
    amplify version

    source .circleci/local_publish_helpers.sh && startLocalRegistry "$CODEBUILD_SRC_DIR/.circleci/verdaccio.yaml"
    source $BASH_ENV

    setNpmRegistryUrlToLocal
    changeNpmGlobalPath
    amplify version

    cd packages/amplify-e2e-tests

    _loadTestAccountCredentials

    retry runE2eTest
}
function _integrationTests {
    #restore cache
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache

    echo $AUTH_CLONE_URL
    echo $API_CLONE_URL
    
    source .circleci/
    # make file executable
    cd .circleci/ && chmod +x aws.sh

    # don't know what this does
    expect .circleci/aws_configure.exp

    # configuring Amplify CLI
    yarn rm-dev-link && yarn link-dev && yarn rm-aa-dev-link && yarn link-aa-dev
    echo 'export PATH="$(yarn global bin):$PATH"' >> $BASH_ENV
    amplify-dev

    # cloning auth test package
    cd ..
    git clone $AUTH_CLONE_URL
    cd aws-amplify-cypress-auth
    yarn --cache-folder ~/.cache/yarn
    yarn add cypress@6.8.0 --save

    cd .circleci/ && chmod +x auth.sh && chmod +x amplify_init.sh && chmod +x amplify_init.exp
    expect .circleci/amplify_init.exp ../aws-amplify-cypress-auth
    expect .circleci/enable_auth.exp
    cd ../aws-amplify-cypress-auth
    yarn --frozen-lockfile --cache-folder ~/.cache/yarn
    cd ../aws-amplify-cypress-auth/src && cat $(find . -type f -name 'aws-exports*')

    # Start auth test server in the background
    cd ../aws-amplify-cypress-auth
    pwd
    yarn start

    # Run cypress test for auth
    cd ../aws-amplify-cypress-auth
    cp ../repo/cypress.json .
    cp -R ../repo/cypress .
    yarn cypress run --spec $(find . -type f -name 'auth_spec*')

    # cleanup scripts
    sudo kill -9 $(lsof -t -i:3000)
    cd .circleci/ && chmod +x delete_auth.sh
    expect .circleci/delete_auth.exp

    # clone API Test Package
    cd ..
    git clone $API_CLONE_URL #TODO: Define this
    cd aws-amplify-cypress-api
    yarn --cache-folder ~/.cache/yarn

    cd .circleci/ && chmod +x api.sh
    expect .circleci/amplify_init.exp ../aws-amplify-cypress-api
    expect .circleci/enable_api.exp
    cd ../aws-amplify-cypress-api
    yarn --frozen-lockfile --cache-folder ~/.cache/yarn
    cd ../aws-amplify-cypress-api/src && cat $(find . -type f -name 'aws-exports*')

    # Start API test server in background
    cd ../aws-amplify-cypress-api
    pwd
    yarn start
    
    # Run cypress tests for API
    cd ../aws-amplify-cypress-api
    yarn add cypress@6.8.0 --save
    cp ../repo/cypress.json .
    cp -R ../repo/cypress .
    yarn cypress run --spec $(find . -type f -name 'api_spec*')

    cd .circleci/ && chmod +x delete_api.sh
    expect .circleci/delete_api.exp

    _scanE2eTestArtifacts

    # storing in cache for auth tests
    storeCache $HOME/aws-amplify-cypress-auth/cypress/videos ~/aws-amplify-cypress-auth/cypress/videos
    storeCache $HOME/aws-amplify-cypress-auth/cypress/screenshots ~/aws-amplify-cypress-auth/cypress/screenshots

    # storing in cache for api tests
    storeCache $HOME/aws-amplify-cypress-api/cypress/videos ~aws-amplify-cypress-api/cypress/videos
    storeCache $HOME/aws-amplify-cypress-api/cypress/screenshots ~aws-amplify-cypress-api/cypress/screenshots

    echo integration tests completed
}
function _cleanupResources {
    #restore cache
    loadCache repo $CODEBUILD_SRC_DIR
    loadCache .cache $HOME/.cache
    
    #loading test account credentials
    _loadTestAccountCredentials

    cd packages/amplify-e2e-tests
    yarn clean-e2e-resources

    storeCache $HOME/packages/amplify-e2e-tests/amplify-e2e-reports repo
}
