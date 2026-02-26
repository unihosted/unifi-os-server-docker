#!/bin/bash

UNIFI_SYSTEM_PROPERTIES="$(mktemp)"
trap "rm -f '$UNIFI_SYSTEM_PROPERTIES'" EXIT

set_property() {
    local key="$1" value="$2"
    local escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    if grep -q "^${key}=" "$UNIFI_SYSTEM_PROPERTIES" 2>/dev/null; then
        sed -i '' "s|^${key}=.*|${key}=${escaped_value}|" "$UNIFI_SYSTEM_PROPERTIES"
    else
        echo "${key}=${value}" >> "$UNIFI_SYSTEM_PROPERTIES"
    fi
}

PASS=0
FAIL=0

assert_file() {
    local desc="$1" expected="$2"
    local actual
    actual="$(cat "$UNIFI_SYSTEM_PROPERTIES")"
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $desc"
        ((PASS++))
    else
        echo "FAIL: $desc"
        echo "  Expected:"
        echo "$expected" | sed 's/^/    /'
        echo "  Actual:"
        echo "$actual" | sed 's/^/    /'
        ((FAIL++))
    fi
}

# --- Test 1: Insert new simple property ---
echo -n "" > "$UNIFI_SYSTEM_PROPERTIES"
set_property "system_ip" "192.168.1.1"
assert_file "Insert new simple property" "system_ip=192.168.1.1"

# --- Test 2: Update existing simple property ---
set_property "system_ip" "10.0.0.1"
assert_file "Update existing simple property" "system_ip=10.0.0.1"

# --- Test 3: Insert property with & in value ---
echo -n "" > "$UNIFI_SYSTEM_PROPERTIES"
set_property "db.mongo.uri" 'mongodb\://root\:root@host\:27017/ace?tls\=false&authSource\=admin'
assert_file "Insert property with & in value" 'db.mongo.uri=mongodb\://root\:root@host\:27017/ace?tls\=false&authSource\=admin'

# --- Test 4: Update property with & in value (the original bug) ---
set_property "db.mongo.uri" 'mongodb\://root\:root@host\:27017/ace?tls\=false&authSource\=admin'
assert_file "Update property with & (should not duplicate)" 'db.mongo.uri=mongodb\://root\:root@host\:27017/ace?tls\=false&authSource\=admin'

# --- Test 5: Update property that was Java-escaped ---
echo -n "" > "$UNIFI_SYSTEM_PROPERTIES"
echo 'db.mongo.uri=mongodb\://root\:root@host\:27017/ace?tls\=false&authSource\=admin' > "$UNIFI_SYSTEM_PROPERTIES"
set_property "db.mongo.uri" 'mongodb\://root\:root@newhost\:27017/ace?tls\=false&authSource\=admin'
assert_file "Update Java-escaped property with new value" 'db.mongo.uri=mongodb\://root\:root@newhost\:27017/ace?tls\=false&authSource\=admin'

# --- Test 6: Multiple properties coexist ---
echo -n "" > "$UNIFI_SYSTEM_PROPERTIES"
set_property "system_ip" "192.168.1.1"
set_property "db.mongo.local" "false"
set_property "db.mongo.uri" 'mongodb\://root\:root@host\:27017/ace?tls\=false&authSource\=admin'
set_property "statdb.mongo.uri" 'mongodb\://root\:root@host\:27017/ace_stat?tls\=false&authSource\=admin'
expected="system_ip=192.168.1.1
db.mongo.local=false
db.mongo.uri=mongodb\://root\:root@host\:27017/ace?tls\=false&authSource\=admin
statdb.mongo.uri=mongodb\://root\:root@host\:27017/ace_stat?tls\=false&authSource\=admin"
assert_file "Multiple properties coexist" "$expected"

# --- Test 7: Update one among multiple properties ---
set_property "db.mongo.uri" 'mongodb\://root\:root@newhost\:27017/ace?tls\=false&authSource\=admin'
expected="system_ip=192.168.1.1
db.mongo.local=false
db.mongo.uri=mongodb\://root\:root@newhost\:27017/ace?tls\=false&authSource\=admin
statdb.mongo.uri=mongodb\://root\:root@host\:27017/ace_stat?tls\=false&authSource\=admin"
assert_file "Update one among multiple properties" "$expected"

# --- Test 8: Value with multiple & characters ---
echo -n "" > "$UNIFI_SYSTEM_PROPERTIES"
set_property "url" "http://host?a=1&b=2&c=3"
assert_file "Insert value with multiple &" "url=http://host?a=1&b=2&c=3"
set_property "url" "http://host?x=1&y=2&z=3"
assert_file "Update value with multiple &" "url=http://host?x=1&y=2&z=3"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
