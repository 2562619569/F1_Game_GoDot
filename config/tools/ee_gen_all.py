# -*- coding: utf-8 -*-
"""ee 命令的兼容包装（用法与官方 CLI 一致）：

GDExcelExporter 的 xlrd 1.2.0 引擎在「Python 3.9+ 且装有 defusedxml」的环境下，
会优先选用 defusedxml.cElementTree（无 ElementTree 类属性），误判
Element_has_iter=False，随后调用 Python 3.9 已移除的 ElementTree.getiterator() 崩溃。
xlrd 实际只用到 ET.parse / ET.iterparse，这里把 xlrd 的 ET 指回标准库即可。

用法:  cd config && python tools/ee_gen_all.py gen-all
"""
import sys
import xml.etree.ElementTree as _std_et

import xlrd.xlsx as _xlrd_xlsx

_xlrd_xlsx.ET = _std_et
_xlrd_xlsx.ET_has_iterparse = True
_xlrd_xlsx.Element_has_iter = True

from gd_excelexporter.cli import cli

cli()
