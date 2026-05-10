#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BT legacy plugin entry wrapper for lowercase and historical mixed-case names."""

from main import main as _Main


class maccmswall_main(_Main):
    """兼容 name=maccmswall 的入口类。"""

    pass


class MacCmsWall_main(maccmswall_main):
    """兼容历史 name=MacCmsWall 的入口类。"""

    pass
