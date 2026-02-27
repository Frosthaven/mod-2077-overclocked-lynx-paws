import? '.justfile.local'

repo := justfile_directory()

# Rebuild WallRunning.archive from localization source
archive:
    rm -rf "{{repo}}/build/WallRunning"
    mkdir -p "{{repo}}/build/WallRunning/wallrunning/localization"
    wolvenkit convert deserialize "{{repo}}/archive/pc/mod/localization-src/en-us.json.json" \
        -o "{{repo}}/build/WallRunning/wallrunning/localization"
    wolvenkit pack "{{repo}}/build/WallRunning" -o "{{repo}}/archive/pc/mod"
    rm -rf "{{repo}}/build/WallRunning"
    @echo "Rebuilt: archive/pc/mod/WallRunning.archive"

# Build release zip
build: archive
    rm -rf "{{repo}}/build/staging"
    mkdir -p "{{repo}}/build/staging"
    cp -r "{{repo}}/bin" "{{repo}}/build/staging/"
    cp -r "{{repo}}/r6" "{{repo}}/build/staging/"
    mkdir -p "{{repo}}/build/staging/archive/pc/mod"
    cp "{{repo}}/archive/pc/mod/WallRunning.archive" "{{repo}}/build/staging/archive/pc/mod/"
    cp "{{repo}}/archive/pc/mod/WallRunning.archive.xl" "{{repo}}/build/staging/archive/pc/mod/"
    find "{{repo}}/build/staging" -name "*.log" -o -name "*.bak" -o -name "*.tmp" -o -name "*.sqlite3" -o -name "settings.json" -o -name "vkd3d-proton.cache.write" | xargs rm -f 2>/dev/null; true
    cd "{{repo}}/build/staging" && zip -r "{{repo}}/build/OverclockedLynxPaws.zip" . -x ".*"
    rm -rf "{{repo}}/build/staging"
    @echo "Built: build/OverclockedLynxPaws.zip"
