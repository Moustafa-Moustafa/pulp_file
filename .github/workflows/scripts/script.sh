#!/usr/bin/env bash
# coding=utf-8

# WARNING: DO NOT EDIT!
#
# This file was generated by plugin_template, and is managed by it. Please use
# './plugin-template --github pulp_file' to update this file.
#
# For more info visit https://github.com/pulp/plugin_template

set -mveuo pipefail

# make sure this script runs at the repo root
cd "$(dirname "$(realpath -e "$0")")"/../../..

source .github/workflows/scripts/utils.sh

export POST_SCRIPT=$PWD/.github/workflows/scripts/post_script.sh
export FUNC_TEST_SCRIPT=$PWD/.github/workflows/scripts/func_test_script.sh

# Needed for both starting the service and building the docs.
# Gets set in .github/settings.yml, but doesn't seem to inherited by
# this script.
export DJANGO_SETTINGS_MODULE=pulpcore.app.settings
export PULP_SETTINGS=$PWD/.ci/ansible/settings/settings.py

export PULP_URL="https://pulp"

if [[ "$TEST" = "docs" ]]; then
  if [[ "$GITHUB_WORKFLOW" == "File CI" ]]; then
    towncrier build --yes --version 4.0.0.ci
  fi
  pulp-docs build
  exit
fi

REPORTED_STATUS="$(pulp status)"

echo "machine pulp
login admin
password password
" | cmd_user_stdin_prefix bash -c "cat >> ~pulp/.netrc"
# Some commands like ansible-galaxy specifically require 600
cmd_prefix bash -c "chmod 600 ~pulp/.netrc"

# Generate bindings
###################

echo "::group::Generate bindings"

touch bindings_requirements.txt
pushd ../pulp-openapi-generator
  # Use app_label to generate api.json and package to produce the proper package name.

  # Workaround: Domains are not supported by the published bindings.
  # Sadly: Different pulpcore-versions aren't either...
  # So we exclude the prebuilt ones only for domains disabled.
  if [ "$(jq -r '.domain_enabled' <<<"${REPORTED_STATUS}")" = "true" ] || [ "$(jq -r '.online_workers[0].pulp_href|startswith("/pulp/api/v3/")' <<< "${REPORTED_STATUS}")" = "false" ]
  then
    BUILT_CLIENTS=""
  else
    BUILT_CLIENTS=" "
  fi

  for ITEM in $(jq -r '.versions[] | tojson' <<<"${REPORTED_STATUS}")
  do
    COMPONENT="$(jq -r '.component' <<<"${ITEM}")"
    VERSION="$(jq -r '.version' <<<"${ITEM}" | python3 -c "from packaging.version import Version; print(Version(input()))")"
    # On older status endpoints, the module was not provided, but the package should be accurate
    # there, because we did not merge plugins into pulpcore back then.
    MODULE="$(jq -r '.module // (.package|gsub("-"; "_"))' <<<"${ITEM}")"
    PACKAGE="${MODULE%%.*}"
    cmd_prefix pulpcore-manager openapi --bindings --component "${COMPONENT}" > "${COMPONENT}-api.json"
    if [[ ! " ${BUILT_CLIENTS} " =~ "${COMPONENT}" ]]
    then
      rm -rf "./${PACKAGE}-client"
      ./gen-client.sh "${COMPONENT}-api.json" "${COMPONENT}" python "${PACKAGE}"
      pushd "${PACKAGE}-client"
        python setup.py sdist bdist_wheel --python-tag py3
      popd
    else
      if [ ! -f "${PACKAGE}-client/dist/${PACKAGE}_client-${VERSION}-py3-none-any.whl" ]
      then
        ls -lR "${PACKAGE}-client/"
        echo "Error: Client bindings for ${COMPONENT} not found."
        echo "File ${PACKAGE}-client/dist/${PACKAGE}_client-${VERSION}-py3-none-any.whl missing."
        exit 1
      fi
    fi
    echo "/root/pulp-openapi-generator/${PACKAGE}-client/dist/${PACKAGE}_client-${VERSION}-py3-none-any.whl" >> "../pulp_file/bindings_requirements.txt"
  done
popd

echo "::endgroup::"

echo "::group::Debug bindings diffs"

echo "::endgroup::"

# Install test requirements
###########################

# Add a safeguard to make sure the proper versions of the clients are installed.
echo "$REPORTED_STATUS" | jq -r '.versions[]|select(.package)|(.package|sub("_"; "-")) + "-client==" + .version' > bindings_constraints.txt
cmd_stdin_prefix bash -c "cat > /tmp/unittest_requirements.txt" < unittest_requirements.txt
cmd_stdin_prefix bash -c "cat > /tmp/functest_requirements.txt" < functest_requirements.txt
cmd_stdin_prefix bash -c "cat > /tmp/bindings_requirements.txt" < bindings_requirements.txt
cmd_stdin_prefix bash -c "cat > /tmp/bindings_constraints.txt" < bindings_constraints.txt
cmd_prefix pip3 install -r /tmp/unittest_requirements.txt -r /tmp/functest_requirements.txt -r /tmp/bindings_requirements.txt -c /tmp/bindings_constraints.txt

CERTIFI=$(cmd_prefix python3 -c 'import certifi; print(certifi.where())')
cmd_prefix bash -c "cat /etc/pulp/certs/pulp_webserver.crt >> '$CERTIFI'"

# check for any uncommitted migrations
echo "Checking for uncommitted migrations..."

# Run unit tests.

if [ -f "$POST_SCRIPT" ]; then
  source "$POST_SCRIPT"
fi
