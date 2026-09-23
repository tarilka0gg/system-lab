-- Готові запити до data/lab.db.   sqlite3 -header -column data/lab.db < stack/queries.sql

-- 1. Межа андервольту CORE: найглибша точка, що пройшла обидва тести
SELECT core_mv, cache_mv, allcore_yc, boost_yc, verdict FROM uv_cache
 ORDER BY CAST(core_mv AS INT), CAST(cache_mv AS INT);

-- 2. Живий throttled.conf проти останньої повністю валідованої точки
SELECT l.section, l.key, f.value AS validated, l.value AS live
  FROM throttled_configs l
  JOIN throttled_configs f ON f.section=l.section AND f.key=l.key
 WHERE l.version='LIVE' AND f.version='throttled.conf.FINAL-150-175-150' AND l.value<>f.value;

-- 3. y-cruncher: що падало
SELECT label, passed, failed_markers FROM yc_runs WHERE verdict<>'PASS';

-- 4. Збірки ядра за результатом
SELECT outcome, COUNT(*) n FROM kernel_build_logs GROUP BY outcome;

-- 5. Пул ядер: 304 зібрані з 4745 комбінацій; 139 з них у status.tsv (останній resume-запуск)
SELECT source, COUNT(*) n, MIN(seconds) min_s, MAX(seconds) max_s FROM kernel_builds GROUP BY source;

-- 6. Сесії журналу за датами
SELECT date, COUNT(*) sessions, GROUP_CONCAT(session) FROM journal_sessions GROUP BY date;

-- 7. Де лежить місце
SELECT grp, COUNT(*) files, ROUND(SUM(bytes)/1048576.0,1) mb FROM files GROUP BY grp ORDER BY mb DESC;
