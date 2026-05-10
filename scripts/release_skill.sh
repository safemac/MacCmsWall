#!/usr/bin/env bash
# 打包技能脚本：封装 README 自动更新与校验文件生成逻辑。

set -u
set -o pipefail

release_skill_md5_of_file() {
    local file_path="$1"

    if command -v md5sum >/dev/null 2>&1; then
        md5sum "${file_path}" | awk '{print $1}'
        return 0
    fi

    if command -v openssl >/dev/null 2>&1; then
        openssl md5 "${file_path}" | awk '{print $NF}'
        return 0
    fi

    if command -v md5 >/dev/null 2>&1; then
        md5 -q "${file_path}"
        return 0
    fi

    return 1
}

release_skill_sha256_of_file() {
    local file_path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file_path}" | awk '{print $1}'
        return 0
    fi

    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "${file_path}" | awk '{print $NF}'
        return 0
    fi

    return 1
}

# 生成核心脚本 MD5 清单，供 onekey/install/update 显式校验。
release_skill_generate_script_md5_manifest() {
    local root_dir="$1"
    local output_file="$2"
    local name file hash

    : > "${output_file}"

    for name in install.sh update.sh uninstall.sh onekey.sh; do
        file="${root_dir}/${name}"
        [ -f "${file}" ] || return 1

        hash="$(release_skill_md5_of_file "${file}" || true)"
        [ -n "${hash}" ] || return 1

        printf "%s  %s\n" "${hash}" "${name}" >> "${output_file}"
    done

    return 0
}

release_skill_generate_artifact_md5() {
    local output_file="$1"
    shift

    : > "${output_file}"

    local file hash
    for file in "$@"; do
        [ -f "${file}" ] || continue
        hash="$(release_skill_md5_of_file "${file}" || true)"
        [ -n "${hash}" ] || return 1
        printf "%s  %s\n" "${hash}" "$(basename "${file}")" >> "${output_file}"
    done

    return 0
}

release_skill_generate_artifact_sha256() {
    local output_file="$1"
    shift

    : > "${output_file}"

    local file hash
    for file in "$@"; do
        [ -f "${file}" ] || continue
        hash="$(release_skill_sha256_of_file "${file}" || true)"
        [ -n "${hash}" ] || return 1
        printf "%s  %s\n" "${hash}" "$(basename "${file}")" >> "${output_file}"
    done

    return 0
}

release_skill_update_readme_release_block() {
    local readme_file="$1"
    local version="$2"
    local md5_file="$3"
    local sha256_file="$4"
    local block_file temp_file

    [ -f "${readme_file}" ] || return 1
    [ -f "${md5_file}" ] || return 1
    [ -f "${sha256_file}" ] || return 1

    block_file="$(mktemp /tmp/maccmswall-readme-block.XXXXXX)"
    temp_file="$(mktemp /tmp/maccmswall-readme-new.XXXXXX)"

    {
        echo "<!-- RELEASE_AUTO_START -->"
        echo "- Last release: v${version}"
        echo "- Built at: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "- One line command:"
        echo ""
        echo '```bash'
        echo "curl -fsSL https://raw.githubusercontent.com/safemac/MacCmsWall/main/onekey.sh | bash"
        echo '```'
        echo ""
        echo "- MD5"
        echo '```text'
        cat "${md5_file}"
        echo '```'
        echo ""
        echo "- SHA256"
        echo '```text'
        cat "${sha256_file}"
        echo '```'
        echo "<!-- RELEASE_AUTO_END -->"
    } > "${block_file}"

    if grep -q "<!-- RELEASE_AUTO_START -->" "${readme_file}" && grep -q "<!-- RELEASE_AUTO_END -->" "${readme_file}"; then
        awk -v start="<!-- RELEASE_AUTO_START -->" -v end="<!-- RELEASE_AUTO_END -->" -v block_file="${block_file}" '
        BEGIN {
            while ((getline line < block_file) > 0) {
                block = block line "\n"
            }
        }
        $0 == start {
            printf "%s", block
            in_block = 1
            next
        }
        in_block && $0 == end {
            in_block = 0
            next
        }
        !in_block { print }
        ' "${readme_file}" > "${temp_file}"
    else
        cat "${readme_file}" > "${temp_file}"
        {
            echo ""
            echo "## Release Auto Info"
            cat "${block_file}"
        } >> "${temp_file}"
    fi

    mv "${temp_file}" "${readme_file}"
    rm -f "${block_file}"

    return 0
}
