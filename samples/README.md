# 样例书籍

本目录中的 EPUB 用于试用 EasyRead、复现 README 截图，正文均为公有领域中文作品：

| 文件 | 书名 | 作者 |
| --- | --- | --- |
| `beijing.epub` | 背影（含《匆匆》《春》《绿》等） | 朱自清 |
| `hetang.epub` | 荷塘月色（含《桨声灯影里的秦淮河》等） | 朱自清 |
| `guxiang.epub` | 故乡 | 鲁迅 |
| `jinan.epub` | 济南的冬天 | 老舍 |
| `tangshi.epub` | 唐诗选 | 蘅塘退士 编 |
| `renjian.epub` | 人间词话 | 王国维 |

把 EPUB 导入 EasyRead 即可阅读。`download.html` 是一个简单的下载索引页，部署为静态网站后可直接点击下载。

## 重新生成

EPUB 已包含在仓库中，一般不需要重新生成。`make_books.py` 使用 Pillow 绘制封面，并依赖 macOS 的宋体 / 苹方字体：

```bash
python3 -m pip install pillow
python3 make_books.py
```

脚本会在本目录覆写对应的 `.epub` 与临时封面 `.jpg` 文件。
