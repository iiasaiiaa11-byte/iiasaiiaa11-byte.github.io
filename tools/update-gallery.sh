#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Авто-обновление галереи сайта AAA Mebeli
#  Сканирует папки gallery/<Категория>/, делает оптимизированные
#  копии в img/gallery/<cat>/, собирает gallery-manifest.json
#  и публикует на сайт (git push).
#
#  Запуск вручную:           bash tools/update-gallery.sh
#  Сборка без публикации:    NOPUSH=1 bash tools/update-gallery.sh
# ═══════════════════════════════════════════════════════════════
set -u

# Папка репозитория = на уровень выше этого скрипта
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

LOG="$REPO/logs/gallery.log"
mkdir -p "$REPO/logs"
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" | tee -a "$LOG"; }

# Пауза перед стартом — чтобы крупные фото успели докопироваться в папку
[ "${DEBOUNCE:-0}" -gt 0 ] 2>/dev/null && sleep "${DEBOUNCE}"

log "─── старт обновления галереи ───"

# Соответствие: папка (русское имя) → код категории на сайте
CATS=("Кухни:kitchen" "ТВ-зоны:tv" "Гардеробы:wardrobe" "Шкафы:closet")

MAX_PX=1600          # максимальная сторона фото (px)
JPEG_QUALITY=72      # качество JPEG (0..100)

MANIFEST="$REPO/gallery-manifest.json"
TMP="$(mktemp)"
echo "{" > "$TMP"

# Печатает пути фото категории (NUL-разделённые) в нужном порядке:
#  • верхний уровень обходится по имени;
#  • если это ПАПКА-проект (одна кухня) — все её фото идут подряд (по имени);
#  • если это отдельный файл-фото — идёт как есть.
# Так фото одного проекта не перемешиваются с другими.
emit_sources(){
    local base="$1"
    [ -d "$base" ] || return 0
    local entry
    while IFS= read -r -d '' entry; do
        if [ -d "$entry" ]; then
            # Папка-проект: все фото внутри, по имени
            find "$entry" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.heic' \) ! -name '.*' -print0 | sort -z
        else
            # Отдельный файл прямо в категории
            case "$entry" in
                *.jpg|*.JPG|*.jpeg|*.JPEG|*.png|*.PNG|*.webp|*.WEBP|*.heic|*.HEIC) printf '%s\0' "$entry";;
            esac
        fi
    done < <(find "$base" -mindepth 1 -maxdepth 1 ! -name '.*' -print0 | sort -z)
}

first_cat=1
for pair in "${CATS[@]}"; do
    folder="${pair%%:*}"
    cat="${pair##*:}"
    src_dir="$REPO/gallery/$folder"
    dst_dir="$REPO/img/gallery/$cat"

    # Чистим и пересоздаём папку оптимизированных копий
    rm -rf "$dst_dir"
    mkdir -p "$dst_dir"

    # Запятая-разделитель между категориями в JSON
    [ $first_cat -eq 1 ] && first_cat=0 || echo "," >> "$TMP"
    printf '  "%s": [' "$cat" >> "$TMP"

    n=0
    first_img=1
    # Фото в порядке проектов (см. emit_sources): фото одной кухни идут подряд
    while IFS= read -r -d '' f; do
        n=$((n+1))
        out="$dst_dir/${cat}-$(printf '%02d' "$n").jpg"
        # Уменьшаем до MAX_PX по длинной стороне и сжимаем в JPEG
        if sips -s format jpeg -s formatOptions "$JPEG_QUALITY" -Z "$MAX_PX" "$f" --out "$out" >/dev/null 2>&1; then
            rel="img/gallery/${cat}/${cat}-$(printf '%02d' "$n").jpg"
            [ $first_img -eq 1 ] && first_img=0 || printf ',' >> "$TMP"
            printf '"%s"' "$rel" >> "$TMP"
        else
            log "  ⚠ не удалось обработать: $f"
            n=$((n-1))
        fi
    done < <(emit_sources "$src_dir")

    printf ']' >> "$TMP"
    log "  $folder → $cat: $n фото"
done

echo "" >> "$TMP"
echo "}" >> "$TMP"
mv "$TMP" "$MANIFEST"
log "  манифест собран: $MANIFEST"

# ─── Публикация ───
if [ "${NOPUSH:-0}" = "1" ]; then
    log "  NOPUSH=1 → публикация пропущена (только локальная сборка)"
    log "─── готово (без публикации) ───"
    exit 0
fi

git add img/gallery gallery-manifest.json >/dev/null 2>&1
if git diff --cached --quiet; then
    log "  изменений нет — публиковать нечего"
else
    git commit -m "auto: обновление галереи $(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1
    if git push origin main >>"$LOG" 2>&1; then
        log "  ✓ опубликовано на сайт (origin/main)"
    else
        log "  ✗ ОШИБКА публикации — см. лог выше"
    fi
fi
log "─── готово ───"
