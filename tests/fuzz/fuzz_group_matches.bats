#!/usr/bin/env bats
# Fuzz tests for _group_matches() — random tag/target combinations

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-100}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    source_common
    source_module "templates.sh"
}

@test "fuzz _group_matches: always outputs 0 or 1" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tag
        tag=$(random_tag)
        local target
        target=$(random_tag 1)
        local result
        result=$(_group_matches "$tag" "$target")
        [[ "$result" == "0" || "$result" == "1" ]] || {
            echo "FAIL iteration $i: tag='$tag' target='$target' result='$result'"
            return 1
        }
    done
}

@test "fuzz _group_matches: known element always returns 1" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tag
        tag=$(random_tag)
        local target
        target=$(echo "$tag" | tr '/' '\n' | shuf | head -1)
        local result
        result=$(_group_matches "$tag" "$target")
        [[ "$result" == "1" ]] || {
            echo "FAIL iteration $i: tag='$tag' target='$target' result='$result'"
            return 1
        }
    done
}

@test "fuzz _group_matches: non-existent element returns 0" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tag
        tag=$(random_tag)
        local target="ZZZZZ_NEVER_${RANDOM}"
        local result
        result=$(_group_matches "$tag" "$target")
        [[ "$result" == "0" ]] || {
            echo "FAIL iteration $i: tag='$tag' target='$target' result='$result'"
            return 1
        }
    done
}

@test "fuzz _group_matches: empty inputs always return 0" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tag="" target="" result
        local variant=$((RANDOM % 3))
        case $variant in
            0) # empty tag, random target
                tag=""
                target=$(random_tag 1)
                ;;
            1) # random tag, empty target
                tag=$(random_tag)
                target=""
                ;;
            2) # both empty
                tag=""
                target=""
                ;;
        esac
        result=$(_group_matches "$tag" "$target")
        [[ "$result" == "0" ]] || {
            echo "FAIL iteration $i variant=$variant: tag='$tag' target='$target' result='$result' (expected 0)"
            return 1
        }
    done
}

@test "fuzz _group_matches: tags with leading/trailing slashes" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local base_tag
        base_tag=$(random_tag)
        local known_elem
        known_elem=$(echo "$base_tag" | tr '/' '\n' | shuf | head -1)
        local tag="$base_tag"
        # Randomly add leading and/or trailing slashes
        (( RANDOM % 2 )) && tag="/$tag"
        (( RANDOM % 2 )) && tag="$tag/"
        local result
        result=$(_group_matches "$tag" "$known_elem")
        [[ "$result" == "1" ]] || {
            echo "FAIL iteration $i: tag='$tag' target='$known_elem' result='$result' (expected 1)"
            return 1
        }
        # Empty target must still return 0 even with slash-padded tags
        result=$(_group_matches "$tag" "")
        [[ "$result" == "0" ]] || {
            echo "FAIL iteration $i: tag='$tag' empty target result='$result' (expected 0)"
            return 1
        }
    done
}

@test "fuzz _group_matches: partial substring never matches" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tag
        tag=$(random_tag)
        local first_elem
        first_elem=$(echo "$tag" | cut -d/ -f1)
        if [[ ${#first_elem} -ge 2 ]]; then
            local partial="${first_elem:0:$((${#first_elem} - 1))}"
            local result
            result=$(_group_matches "$tag" "$partial")
            [[ "$result" == "0" ]] || {
                echo "FAIL: tag='$tag' partial='$partial' should not match, got $result"
                return 1
            }
        fi
    done
}

@test "fuzz _group_matches: duplicate elements still match" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local base_tag
        base_tag=$(random_tag)
        local elem
        elem=$(echo "$base_tag" | tr '/' '\n' | shuf | head -1)
        # Duplicate the element 1-4 times
        local dups=$((RANDOM % 4 + 1))
        local tag="$base_tag"
        for ((d = 0; d < dups; d++)); do
            tag+="/$elem"
        done
        local result
        result=$(_group_matches "$tag" "$elem")
        [[ "$result" == "1" ]] || {
            echo "FAIL iteration $i: tag='$tag' elem='$elem' result='$result' (expected 1)"
            return 1
        }
    done
}
