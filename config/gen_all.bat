@rem ee 官方 CLI 在装了 defusedxml 的 Python 3.9+ 环境会被 xlrd 1.2.0 卡住，走兼容包装
python tools\ee_gen_all.py gen-all
pause
