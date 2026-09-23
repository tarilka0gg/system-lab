.PHONY: db queries check
db:        ## перебудувати data/lab.db з CSV/логів/журналу
	python3 stack/build_db.py
queries:   ## прогнати stack/queries.sql
	sqlite3 -header -column data/lab.db < stack/queries.sql
check:     ## синтаксис усіх скриптів
	@for f in victus-tuning/scripts/*.sh victus-tuning/restore.sh kernel/scripts/*.sh; do bash -n $$f || exit 1; done
	@python3 -m py_compile victus-tuning/scripts/*.py stack/build_db.py && echo ok
