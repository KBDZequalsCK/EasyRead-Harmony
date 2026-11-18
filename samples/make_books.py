#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate clean EPUB3 samples (public-domain Chinese texts) for EasyRead screenshots."""
import os, zipfile, uuid, html, io
from PIL import Image, ImageDraw, ImageFont

BASE = os.path.dirname(os.path.abspath(__file__))
SONG = "/System/Library/Fonts/Supplemental/Songti.ttc"
PING = "/System/Library/Fonts/PingFang.ttc"


def font(path, size, index=0):
    return ImageFont.truetype(path, size, index=index)


PALETTES = {
    "beijing":  ((243, 236, 224), (74, 54, 40), (196, 179, 154)),
    "hetang":   ((232, 239, 232), (36, 66, 50), (178, 199, 178)),
    "guxiang":  ((236, 232, 224), (44, 50, 58), (183, 177, 166)),
    "jinan":    ((231, 237, 240), (40, 56, 66), (171, 188, 196)),
    "tangshi":  ((246, 238, 219), (126, 84, 40), (213, 190, 148)),
    "renjian":  ((236, 235, 231), (38, 38, 36), (186, 183, 176)),
}

BOOKS = [
    {
        "file": "beijing", "title": "背影", "author": "朱自清", "genre": "散文集",
        "chapters": [
            ("背影", [
                "我与父亲不相见已二年余了，我最不能忘记的是他的背影。",
                "那年冬天，祖母死了，父亲的差使也交卸了，正是祸不单行的日子。我从北京到徐州，打算跟着父亲奔丧回家。到徐州见着父亲，看见满院狼藉的东西，又想起祖母，不禁簌簌地流下眼泪。父亲说：“事已如此，不必难过，好在天无绝人之路！”",
                "回家变卖典质，父亲还了亏空；又借钱办了丧事。这些日子，家中光景很是惨淡，一半为了丧事，一半为了父亲赋闲。丧事完毕，父亲要到南京谋事，我也要回北京念书，我们便同行。",
                "到南京时，有朋友约去游逛，勾留了一日；第二日上午便须渡江到浦口，下午上车北去。父亲因为事忙，本已说定不送我，叫旅馆里一个熟识的茶房陪我同去。他再三嘱咐茶房，甚是仔细。但他终于不放心，怕茶房不妥帖；颇踌躇了一会。其实我那年已二十岁，北京已来往过两三次，是没有什么要紧的了。他踌躇了一会，终于决定还是自己送我去。我再三劝他不必去；他只说：“不要紧，他们去不好！”",
                "我们过了江，进了车站。我买票，他忙着照看行李。行李太多了，得向脚夫行些小费才可过去。他便又忙着和他们讲价钱。我那时真是聪明过分，总觉他说话不大漂亮，非自己插嘴不可，但他终于讲定了价钱；就送我上车。",
                "他给我拣定了靠车门的一张椅子；我将他给我做的紫毛大衣铺好座位。他嘱我路上小心，夜里要警醒些，不要受凉。又嘱托茶房好好照应我。我心里暗笑他的迂；他们只认得钱，托他们只是白托！而且我这样大年纪的人，难道还不能料理自己么？唉，我现在想想，那时真是太聪明了！",
                "我说道：“爸爸，你走吧。”他往车外看了看说：“我买几个橘子去。你就在此地，不要走动。”我看那边月台的栅栏外有几个卖东西的等着顾客。走到那边月台，须穿过铁道，须跳下去又爬上去。父亲是一个胖子，走过去自然要费事些。我本来要去的，他不肯，只好让他去。",
                "我看见他戴着黑布小帽，穿着黑布大马褂，深青布棉袍，蹒跚地走到铁道边，慢慢探身下去，尚不大难。可是他穿过铁道，要爬上那边月台，就不容易了。他用两手攀着上面，两脚再向上缩；他肥胖的身子向左微倾，显出努力的样子。这时我看见他的背影，我的泪很快地流下来了。",
            ]),
            ("匆匆", [
                "燕子去了，有再来的时候；杨柳枯了，有再青的时候；桃花谢了，有再开的时候。但是，聪明的，你告诉我，我们的日子为什么一去不复返呢？——是有人偷了他们罢：那是谁？又藏在何处呢？是他们自己逃走了罢：现在又到了哪里呢？",
                "我不知道他们给了我多少日子，但我的手确乎是渐渐空虚了。在默默里算着，八千多日子已经从我手中溜去，像针尖上一滴水滴在大海里，我的日子滴在时间的流里，没有声音，也没有影子。我不禁头涔涔而泪潸潸了。",
                "去的尽管去了，来的尽管来着，去来的中间，又怎样地匆匆呢？早上我起来的时候，小屋里射进两三方斜斜的太阳。太阳他有脚啊，轻轻悄悄地挪移了，我也茫茫然跟着旋转。",
                "于是——洗手的时候，日子从水盆里过去；吃饭的时候，日子从饭碗里过去；默默时，便从凝然的双眼前过去。我觉察他去的匆匆了，伸出手遮挽时，他又从遮挽着的手边过去，天黑时，我躺在床上，他便伶伶俐俐地从我身上跨过，从我脚边飞去了。",
                "等我睁开眼和太阳再见，这算又溜走了一日。我掩着面叹息。但是新来的日子的影儿又开始在叹息里闪过了。",
                "在逃去如飞的日子里，在千门万户的世界里的我能做些什么呢？只有徘徊罢了，只有匆匆罢了；在八千多日的匆匆里，除徘徊外，又剩些什么呢？过去的日子如轻烟，被微风吹散了，如薄雾，被初阳蒸融了；我留着些什么痕迹呢？",
            ]),
            ("春", [
                "盼望着，盼望着，东风来了，春天的脚步近了。",
                "一切都像刚睡醒的样子，欣欣然张开了眼。山朗润起来了，水涨起来了，太阳的脸红起来了。",
                "小草偷偷地从土里钻出来，嫩嫩的，绿绿的。园子里，田野里，瞧去，一大片一大片满是的。坐着，躺着，打两个滚，踢几脚球，赛几趟跑，捉几回迷藏。风轻悄悄的，草软绵绵的。",
                "桃树、杏树、梨树，你不让我，我不让你，都开满了花赶趟儿。红的像火，粉的像霞，白的像雪。花里带着甜味儿；闭了眼，树上仿佛已经满是桃儿、杏儿、梨儿。",
                "“吹面不寒杨柳风”，不错的，像母亲的手抚摸着你。风里带来些新翻的泥土的气息，混着青草味儿，还有各种花的香，都在微微润湿的空气里酝酿。",
                "雨是最寻常的，一下就是三两天。可别恼。看，像牛毛，像花针，像细丝，密密地斜织着，人家屋顶上全笼着一层薄烟。树叶儿却绿得发亮，小草儿也青得逼你的眼。",
                "天上风筝渐渐多了，地上孩子也多了。城里乡下，家家户户，老老小小，他们也赶趟儿似的，一个个都出来了。舒活舒活筋骨，抖擞抖擞精神，各做各的一份事去。“一年之计在于春”，刚起头儿，有的是工夫，有的是希望。",
            ]),
            ("绿", [
                "我第二次到仙岩的时候，我惊诧于梅雨潭的绿了。",
                "梅雨潭是一个瀑布潭。仙岩有三个瀑布，梅雨瀑最低。走到山边，便听见哗哗哗哗的声音；抬起头，镶在两条湿湿的黑边儿里的，一带白而发亮的水便呈现于眼前了。",
                "我们先到梅雨亭。梅雨亭正对着那条瀑布；坐在亭边，不必仰头，便可见它的全体了。亭下深深的便是梅雨潭。这个亭踞在突出的一角的岩石上，上下都空空儿的；仿佛一只苍鹰展着翼翅浮在天宇中一般。",
                "那瀑布从上面冲下，仿佛已被扯成大小的几绺；不复是一幅整齐而平滑的布。岩上有许多棱角；瀑流经过时，作急剧的撞击，便飞花碎玉般乱溅着了。那溅着的水花，晶莹而多芒；远望去，像一朵朵小小的白梅，微雨似的纷纷落着。",
                "梅雨潭闪闪的绿色招引着我们；我们开始追捉她那离合的神光了。揪着草，攀着乱石，小心探身下去，又鞠躬过了一个石穹门，便到了汪汪一碧的潭边了。",
                "瀑布在襟袖之间；但我的心中已没有瀑布了。我的心随潭水的绿而摇荡。那醉人的绿呀！仿佛一张极大极大的荷叶铺着，满是奇异的绿呀。我想张开两臂抱住她；但这是怎样一个妄想呀。",
            ]),
        ],
    },
    {
        "file": "hetang", "title": "荷塘月色", "author": "朱自清", "genre": "散文集",
        "chapters": [
            ("荷塘月色", [
                "这几天心里颇不宁静。今晚在院子里坐着乘凉，忽然想起日日走过的荷塘，在这满月的光里，总该另有一番样子吧。月亮渐渐地升高了，墙外马路上孩子们的欢笑，已经听不见了；妻在屋里拍着闰儿，迷迷糊糊地哼着眠歌。我悄悄地披了大衫，带上门出去。",
                "沿着荷塘，是一条曲折的小煤屑路。这是一条幽僻的路；白天也少人走，夜晚更加寂寞。荷塘四面，长着许多树，蓊蓊郁郁的。路的一旁，是些杨柳，和一些不知道名字的树。没有月光的晚上，这路上阴森森的，有些怕人。今晚却很好，虽然月光也还是淡淡的。",
                "路上只我一个人，背着手踱着。这一片天地好像是我的；我也像超出了平常的自己，到了另一世界里。我爱热闹，也爱冷静；爱群居，也爱独处。像今晚上，一个人在这苍茫的月下，什么都可以想，什么都可以不想，便觉是个自由的人。",
                "曲曲折折的荷塘上面，弥望的是田田的叶子。叶子出水很高，像亭亭的舞女的裙。层层的叶子中间，零星地点缀着些白花，有袅娜地开着的，有羞涩地打着朵儿的；正如一粒粒的明珠，又如碧天里的星星，又如刚出浴的美人。",
                "微风过处，送来缕缕清香，仿佛远处高楼上渺茫的歌声似的。这时候叶子与花也有一丝的颤动，像闪电般，霎时传过荷塘的那边去了。叶子本是肩并肩密密地挨着，这便宛然有了一道凝碧的波痕。",
                "月光如流水一般，静静地泻在这一片叶子和花上。薄薄的青雾浮起在荷塘里。叶子和花仿佛在牛乳中洗过一样；又像笼着轻纱的梦。虽然是满月，天上却有一层淡淡的云，所以不能朗照；但我以为这恰是到了好处——酣眠固不可少，小睡也别有风味的。",
                "月光是隔了树照过来的，高处丛生的灌木，落下参差的斑驳的黑影，峭楞楞如鬼一般；弯弯的杨柳的稀疏的倩影，却又像是画在荷叶上。塘中的月色并不均匀；但光与影有着和谐的旋律，如梵婀玲上奏着的名曲。",
            ]),
            ("桨声灯影里的秦淮河", [
                "一九二三年八月的一晚，我和平伯同游秦淮河；平伯是初泛，我是重来了。我们雇了一只“七板子”，在夕阳已去，皎月方来的时候，便下了船。于是桨声汩——汩，我们开始领略那晃荡着蔷薇色的历史的秦淮河的滋味了。",
                "秦淮河里的船，比北京万甡园、颐和园的船好，比西湖的船好，比扬州瘦西湖的船也好。这几处的船不是觉着笨，就是觉着简陋、局促；都不能引起乘客们的情韵，如秦淮河的船一样。",
                "秦淮河的水是碧阴阴的；看起来厚而不腻，或者是六朝金粉所凝么？我们初上船的时候，天色还未断黑，那漾漾的柔波是这样恬静，委婉，使我们一面有水阔天空之想，一面又憧憬着纸醉金迷之境了。",
                "等到灯火明时，阴阴的变为沉沉了：黯淡的水光，像梦一般；那偶然闪烁着的光芒，就是梦的眼睛了。我们坐在舱前，因了那隆起的顶棚，仿佛总是昂着首向前走着似的；于是飘飘然如御风而行的我们，看着那些自在的湾泊着的船，船里走马灯般的人物，便像是下界一般，迢迢的远了。",
                "这时我们已过了利涉桥，望见东关头了。沿路听见断续的歌声：有从沿河的妓楼飘来的，有从河上船里度来的。我们明知那些歌声，只是些因袭的言词，从生涩的歌喉里机械的发出来的；但它们经了夏夜的微风的吹漾和水波的摇拂，袅娜着到我们耳边的时候，已经不单是她们的歌声，而混着微风和河水的密语了。",
            ]),
            ("冬天", [
                "说起冬天，忽然想到豆腐。是一“小洋锅”白煮豆腐，热腾腾的。水滚着，像好些鱼眼睛，一小块一小块豆腐养在里面，嫩而滑，仿佛反穿的白狐大衣。锅在“洋炉子”上，和炉子都熏得乌黑乌黑，越显出豆腐的白。",
                "这是晚上，屋子老了，虽点着“洋灯”，也还是阴暗。围着桌子坐的是父亲跟我们哥儿三个。“洋炉子”太高了，父亲得常常站起来，微微地仰着脸，觑着眼睛，从氤氲的热气里伸进筷子，夹起豆腐，一一地放在我们的酱油碟里。",
                "我们有时也自己动手，但炉子实在太高了，总还是坐享其成的多。这并不是吃饭，只是玩儿。父亲说晚上冷，吃了大家暖和些。我们都喜欢这种白水豆腐；一上桌就眼巴巴望着那锅，等着那热气，等着热气里从父亲筷子上掉下来的豆腐。",
                "又是冬天，记得是阴历十一月十六晚上，跟S君P君在西湖里坐小划子。S君刚到杭州教书，事先来信说：“我们要游西湖，不管它是冬天。”那晚月色真好，现在想起来还像照在身上。",
                "在台州过了一个冬天，一家四口子。台州是个山城，可以说在一个大谷里。只有一条二里长的大街。别的路上白天简直不大见人；晚上一片漆黑。偶尔人家窗户里透出一点灯光，还有走路的拿着的火把；但那是少极了。",
            ]),
        ],
    },
    {
        "file": "guxiang", "title": "故乡", "author": "鲁迅", "genre": "小说集",
        "chapters": [
            ("故乡", [
                "我冒了严寒，回到相隔二千余里，别了二十余年的故乡去。",
                "时候既然是深冬；渐近故乡时，天气又阴晦了，冷风吹进船舱中，呜呜的响，从篷隙向外一望，苍黄的天底下，远近横着几个萧索的荒村，没有一些活气。我的心禁不住悲凉起来了。",
                "阿！这不是我二十年来时时记得的故乡？",
                "我所记得的故乡全不如此。我的故乡好得多了。但要我记起他的美丽，说出他的佳处来，却又没有影像，没有言辞了。仿佛也就如此。于是我自己解释说：故乡本也如此，——虽然没有进步，也未必有如我所感的悲凉，这只是我自己心情的改变罢了，因为我这次回乡，本没有什么好心绪。",
                "我于是日日盼望新年，新年到，闰土也就到了。好容易到了年末，有一日，母亲告诉我，闰土来了，我便飞跑的去看。他正在厨房里，紫色的圆脸，头戴一顶小毡帽，颈上套一个明晃晃的银项圈，这可见他的父亲十分爱他，怕他死去，所以在神佛面前许下愿心，用圈子将他套住了。",
                "我们那时候不知道谈些什么，只记得闰土很高兴，说是上城之后，见了许多没有见过的东西。第二日，我便要他捕鸟。他说：“这不能。须大雪下了才好。我们沙地上，下了雪，我扫出一块空地来，用短棒支起一个大竹匾，撒下秕谷，看鸟雀来吃时，我远远地将缚在棒上的绳子只一拉，那鸟雀就罩在竹匾下了。什么都有：稻鸡，角鸡，鹁鸪，蓝背……”",
                "我这时很兴奋，但不知道怎么说才好，只是说：“阿！闰土哥，——你来了？……”我接着便有许多话，想要连珠一般涌出：角鸡，跳鱼儿，贝壳，猹，……但又总觉得被什么挡着似的，单在脑里面回旋，吐不出口外去。",
                "他站住了，脸上现出欢喜和凄凉的神情；动着嘴唇，却没有作声。他的态度终于恭敬起来了，分明的叫道：“老爷！……”我似乎打了一个寒噤；我就知道，我们之间已经隔了一层可悲的厚障壁了。我也说不出话。",
            ]),
            ("社戏", [
                "我在倒数上去的二十年中，只看过两回中国戏，前十年是绝不看，因为没有看戏的意思和机会，那两回全在后十年，然而都没有看出什么来就走了。",
                "第一回是民国元年我初到北京的时候，当时一个朋友对我说，北京戏最好，你不去见见世面么？我想，看戏是有味的，而况在北京呢。于是都兴致勃勃的跑到什么园，戏文已经开场了，在外面也早听到冬冬地响。",
                "我们鲁镇的习惯，本来是凡有出嫁的女儿，倘自己还未当家，夏间便大抵回到母家去消夏。那时我的祖母虽然还康健，但母亲也已分担了些家务，所以夏期便不能多日的归省了，只得在扫墓完毕之后，抽空去住几天，这时我便每年跟了我的母亲住在外祖母的家里。",
                "那地方叫平桥村，是一个离海边不远，极偏僻的，临河的小村庄；住户不满三十家，都种田，打鱼，只有一家很小的杂货店。但在我是乐土：因为我在这里不但得到优待，又可以免念“秩秩斯干幽幽南山”了。",
                "我的很重的心忽而轻松了，身体也似乎舒展到说不出的大。一出门，便望见月下的平桥内泊着一只白篷的航船，大家跳下船，双喜拔前篙，阿发拔后篙，年幼的都陪我坐在舱中，较大的聚在船尾。母亲送出来吩咐“要小心”的时候，我们已经点开船，在桥石上一磕，退后几尺，即又上前出了桥。",
                "两岸的豆麦和河底的水草所发散出来的清香，夹杂在水气中扑面的吹来；月色便朦胧在这水气里。淡黑的起伏的连山，仿佛是踊跃的铁的兽脊似的，都远远地向船尾跑去了，但我却还以为船慢。",
            ]),
            ("孔乙己", [
                "鲁镇的酒店的格局，是和别处不同的：都是当街一个曲尺形的大柜台，柜里面预备着热水，可以随时温酒。做工的人，傍午傍晚散了工，每每花四文铜钱，买一碗酒，——这是二十多年前的事，现在每碗要涨到十文，——靠柜外站着，热热的喝了休息。",
                "孔乙己是站着喝酒而穿长衫的唯一的人。他身材很高大；青白脸色，皱纹间时常夹些伤痕；一部乱蓬蓬的花白的胡子。穿的虽然是长衫，可是又脏又破，似乎十多年没有补，也没有洗。",
                "他对人说话，总是满口之乎者也，教人半懂不懂的。因为他姓孔，别人便从描红纸上的“上大人孔乙己”这半懂不懂的话里，替他取下一个绰号，叫作孔乙己。",
                "听人家背地里谈论，孔乙己原来也读过书，但终于没有进学，又不会营生；于是愈过愈穷，弄到将要讨饭了。幸而写得一笔好字，便替人家钞钞书，换一碗饭吃。",
                "孔乙己一到店，所有喝酒的人便都看着他笑，有的叫道：“孔乙己，你脸上又添上新伤疤了！”他不回答，对柜里说：“温两碗酒，要一碟茴香豆。”便排出九文大钱。",
            ]),
        ],
    },
    {
        "file": "jinan", "title": "济南的冬天", "author": "老舍", "genre": "散文集",
        "chapters": [
            ("济南的冬天", [
                "对于一个在北平住惯的人，像我，冬天要是不刮风，便觉得是奇迹；济南的冬天是没有风声的。对于一个刚由伦敦回来的人，像我，冬天要能看得见日光，便觉得是怪事；济南的冬天是响晴的。",
                "自然，在热带的地方，日光是永远那么毒，响亮的天气，反有点叫人害怕。可是，在北中国的冬天，而能有温晴的天气，济南真得算个宝地。",
                "设若单单是有阳光，那也算不了出奇。请闭上眼睛想：一个老城，有山有水，全在天底下晒着阳光，暖和安适地睡着，只等春风来把它们唤醒，这是不是个理想的境界？",
                "小山整把济南围了个圈儿，只有北边缺着点口儿。这一圈小山在冬天特别可爱，好像是把济南放在一个小摇篮里，它们安静不动地低声地说：“你们放心吧，这儿准保暖和。”",
                "最妙的是下点小雪呀。看吧，山上的矮松越发的青黑，树尖上顶着一髻儿白花，好像日本看护妇。山尖全白了，给蓝天镶上一道银边。",
                "山坡上，有的地方雪厚点，有的地方草色还露着；这样，一道儿白，一道儿暗黄，给山们穿上一件带水纹的花衣；看着看着，这件花衣好像被风儿吹动，叫你希望看见一点更美的山的肌肤。",
                "那水呢，不但不结冰，倒反在绿萍上冒着点热气，水藻真绿，把终年贮蓄的绿色全拿出来了。天儿越晴，水藻越绿，就凭这些绿的精神，水也不忍得冻上，况且那些长枝的垂柳还要在水里照个影儿呢！",
            ]),
            ("趵突泉", [
                "千佛山、大明湖和趵突泉，是济南的三大名胜，现在单讲趵突泉。",
                "在西门外的桥上，便看见一溪活水，清浅，鲜洁，由南向北的流着。这就是由趵突泉流出来的。设若没有这泉，济南定会丢失了一半的美。",
                "泉太好了。泉池差不多见方，三个泉口偏西，北边便是条小溪流向西门去。看那三个大泉，一年四季，昼夜不停，老那么翻滚。你立定呆呆的看三分钟，你便觉出自然的伟大，使你不敢再正眼去看。",
                "永远那么纯洁，永远那么活泼，永远那么鲜明，冒，冒，冒，永不疲乏，永不退缩，只是自然有这样的力量！冬天更好，泉上起了一片热气，白而轻软，在深绿的长长的水藻上飘荡着，不由你不想起一种似乎神秘的境界。",
                "池边还有小泉呢：有的像大鱼吐水，极轻快的上来一串水泡；有的像一串明珠，走到中途又歪下去，真像一串珍珠在水里斜放着；有的半天才上来一个水泡，大，扁一点，慢慢的，有姿态的，摇动上来；碎了；看，又来了一个！",
                "有的好几串小碎珠一齐挤上来，像一朵攒得很整齐的珠花，雪白；有的……这比那大泉还更有味。",
            ]),
            ("猫", [
                "猫的性格实在有些古怪。说它老实吧，它的确有时候很乖。它会找个暖和的地方，成天睡大觉，无忧无虑，什么事也不过问。可是，它决定要出去玩玩，就会出走一天一夜，任凭谁怎么呼唤，它也不肯回来。",
                "说它贪玩吧，的确是呀，要不怎么会一天一夜不回家呢？可是，它听到老鼠的一点响动，又是多么尽职。它屏息凝视，一连就是几个钟头，非把老鼠等出来不可！",
                "它要是高兴，能比谁都温柔可亲：用身子蹭你的腿，把脖儿伸出来要求给抓痒，或是在你写作的时候，跳上桌来，在稿纸上踩印几朵小梅花。它还会丰富多腔地叫唤，长短不同，粗细各异，变化多端。",
                "它什么都怕，总想藏起来。可是它又那么勇猛，不要说见着小虫和老鼠，就是遇上蛇也敢斗一斗。",
                "小猫满月的时候更可爱，腿脚还不稳，可是已经学会淘气。一根鸡毛，一个线团，都是它的好玩具，耍个没完没了。一玩起来，它不知要摔多少跟头，但是跌倒了马上起来，再跑再跌。",
            ]),
        ],
    },
    {
        "file": "tangshi", "title": "唐诗选", "author": "蘅塘退士 编", "genre": "唐诗选本",
        "chapters": [
            ("五言绝句", [
                ("静夜思", "李白", "床前明月光，疑是地上霜。\n举头望明月，低头思故乡。"),
                ("春晓", "孟浩然", "春眠不觉晓，处处闻啼鸟。\n夜来风雨声，花落知多少。"),
                ("登鹳雀楼", "王之涣", "白日依山尽，黄河入海流。\n欲穷千里目，更上一层楼。"),
                ("相思", "王维", "红豆生南国，春来发几枝。\n愿君多采撷，此物最相思。"),
                ("江雪", "柳宗元", "千山鸟飞绝，万径人踪灭。\n孤舟蓑笠翁，独钓寒江雪。"),
                ("鹿柴", "王维", "空山不见人，但闻人语响。\n返景入深林，复照青苔上。"),
            ]),
            ("七言绝句", [
                ("枫桥夜泊", "张继", "月落乌啼霜满天，江枫渔火对愁眠。\n姑苏城外寒山寺，夜半钟声到客船。"),
                ("凉州词", "王之涣", "黄河远上白云间，一片孤城万仞山。\n羌笛何须怨杨柳，春风不度玉门关。"),
                ("送元二使安西", "王维", "渭城朝雨浥轻尘，客舍青青柳色新。\n劝君更尽一杯酒，西出阳关无故人。"),
                ("早发白帝城", "李白", "朝辞白帝彩云间，千里江陵一日还。\n两岸猿声啼不住，轻舟已过万重山。"),
                ("山行", "杜牧", "远上寒山石径斜，白云生处有人家。\n停车坐爱枫林晚，霜叶红于二月花。"),
            ]),
            ("五言律诗", [
                ("春望", "杜甫", "国破山河在，城春草木深。\n感时花溅泪，恨别鸟惊心。\n烽火连三月，家书抵万金。\n白头搔更短，浑欲不胜簪。"),
                ("山居秋暝", "王维", "空山新雨后，天气晚来秋。\n明月松间照，清泉石上流。\n竹喧归浣女，莲动下渔舟。\n随意春芳歇，王孙自可留。"),
                ("望岳", "杜甫", "岱宗夫如何？齐鲁青未了。\n造化钟神秀，阴阳割昏晓。\n荡胸生曾云，决眦入归鸟。\n会当凌绝顶，一览众山小。"),
            ]),
            ("七言律诗", [
                ("黄鹤楼", "崔颢", "昔人已乘黄鹤去，此地空余黄鹤楼。\n黄鹤一去不复返，白云千载空悠悠。\n晴川历历汉阳树，芳草萋萋鹦鹉洲。\n日暮乡关何处是？烟波江上使人愁。"),
                ("登高", "杜甫", "风急天高猿啸哀，渚清沙白鸟飞回。\n无边落木萧萧下，不尽长江滚滚来。\n万里悲秋常作客，百年多病独登台。\n艰难苦恨繁霜鬓，潦倒新停浊酒杯。"),
                ("锦瑟", "李商隐", "锦瑟无端五十弦，一弦一柱思华年。\n庄生晓梦迷蝴蝶，望帝春心托杜鹃。\n沧海月明珠有泪，蓝田日暖玉生烟。\n此情可待成追忆，只是当时已惘然。"),
            ]),
        ],
    },
    {
        "file": "renjian", "title": "人间词话", "author": "王国维", "genre": "词话",
        "chapters": [
            ("卷一", [
                "词以境界为最上。有境界则自成高格，自有名句。五代北宋之词所以独绝者在此。",
                "有造境，有写境，此理想与写实二派之所由分。然二者颇难分别。因大诗人所造之境，必合乎自然，所写之境，亦必邻于理想故也。",
                "有有我之境，有无我之境。“泪眼问花花不语，乱红飞过秋千去。”“可堪孤馆闭春寒，杜鹃声里斜阳暮。”有我之境也。“采菊东篱下，悠然见南山。”“寒波澹澹起，白鸟悠悠下。”无我之境也。",
                "无我之境，人惟于静中得之。有我之境，于由动之静时得之。故一优美，一宏壮也。",
                "自然中之物，互相关系，互相限制。然其写之于文学及美术中也，必遗其关系、限制之处。故虽写实家，亦理想家也。",
                "境非独谓景物也。喜怒哀乐，亦人心中之一境界。故能写真景物、真感情者，谓之有境界。否则谓之无境界。",
            ]),
            ("卷二", [
                "古今之成大事业、大学问者，必经过三种之境界：“昨夜西风凋碧树。独上高楼，望尽天涯路。”此第一境也。“衣带渐宽终不悔，为伊消得人憔悴。”此第二境也。“众里寻他千百度，蓦然回首，那人却在，灯火阑珊处。”此第三境也。",
                "此等语皆非大词人不能道。然遽以此意解释诸词，恐为晏欧诸公所不许也。",
                "太白纯以气象胜。“西风残照，汉家陵阙。”寥寥八字，遂关千古登临之口。后世唯范文正之《渔家傲》、夏英公之《喜迁莺》，差足继武，然气象已不逮矣。",
                "南唐中主词：“菡萏香销翠叶残，西风愁起绿波间。”大有众芳芜秽，美人迟暮之感。乃古今独赏其“细雨梦回鸡塞远，小楼吹彻玉笙寒”。故知解人正不易得。",
                "温飞卿之词，句秀也。韦端己之词，骨秀也。李重光之词，神秀也。",
            ]),
            ("卷三", [
                "词至李后主而眼界始大，感慨遂深，遂变伶工之词而为士大夫之词。周介存置诸温韦之下，可谓颠倒黑白矣。",
                "“自是人生长恨水长东。”“流水落花春去也，天上人间。”《金荃》《浣花》，能有此气象耶？",
                "客观之诗人，不可不多阅世。阅世愈深，则材料愈丰富，愈变化，《水浒传》《红楼梦》之作者是也。主观之诗人，不必多阅世。阅世愈浅，则性情愈真，李后主是也。",
                "尼采谓：“一切文学，余爱以血书者。”后主之词，真所谓以血书者也。宋道君皇帝《燕山亭》词亦略似之。然道君不过自道身世之戚，后主则俨有释迦、基督担荷人类罪恶之意，其大小固不同矣。",
                "大家之作，其言情也必沁人心脾，其写景也必豁人耳目。其辞脱口而出，无矫揉妆束之态。以其所见者真，所知者深也。诗词皆然。持此以衡古今之作者，可无大误矣。",
            ]),
        ],
    },
]


def draw_cover(book):
    bg, ink, line = PALETTES[book["file"]]
    img = Image.new("RGB", (800, 1200), bg)
    d = ImageDraw.Draw(img)
    # subtle paper texture
    import random
    random.seed(book["file"])
    for _ in range(9000):
        x = random.randrange(800); y = random.randrange(1200)
        c = tuple(max(0, min(255, v + random.randint(-4, 4))) for v in bg)
        d.point((x, y), fill=c)
    # border
    d.rectangle([48, 48, 751, 1151], outline=line, width=2)
    # faint arcs
    for i, r in enumerate((430, 380, 330)):
        shade = tuple(int(bg[k] * 0.72 + line[k] * 0.28) for k in range(3))
        d.arc([400 - r - i * 26, 520 - r, 400 + r - i * 26, 520 + r], 200, 340, fill=shade, width=2)
    # vertical title
    title_font = font(SONG, 132)
    x = 610
    y = 142
    for ch in book["title"]:
        d.text((x, y), ch, font=title_font, fill=ink)
        y += 148
    # accent rule
    d.line([90, 965, 245, 965], fill=ink, width=3)
    # author + genre
    d.text((90, 995), book["author"], font=font(PING, 42), fill=ink)
    d.text((90, 1058), book["genre"], font=font(PING, 27), fill=tuple(int(ink[k] * 0.7 + bg[k] * 0.3) for k in range(3)))
    # small mark at bottom right
    d.text((640, 1085), "EASYREAD", font=font(PING, 17), fill=tuple(int(ink[k] * 0.55 + bg[k] * 0.45) for k in range(3)))
    out = os.path.join(BASE, book["file"] + ".jpg")
    img.save(out, quality=92)
    return out


def chapter_doc(title, paragraphs):
    ps = "\n".join("    <p>%s</p>" % html.escape(p) for p in paragraphs)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN" lang="zh-CN">
<head>
  <meta charset="utf-8"/>
  <title>{html.escape(title)}</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
  <section epub:type="chapter" xmlns:epub="http://www.idpf.org/2007/ops">
    <h1>{html.escape(title)}</h1>
{ps}
  </section>
</body>
</html>
"""


def poem_doc(chapter_title, poems):
    parts = [f"<h1>{html.escape(chapter_title)}</h1>"]
    for title, author, body in poems:
        parts.append('    <div class="poem">')
        parts.append(f'      <h2>{html.escape(title)}</h2>')
        parts.append(f'      <p class="author">{html.escape(author)}</p>')
        for line in body.split("\n"):
            parts.append(f'      <p class="verse">{html.escape(line)}</p>')
        parts.append("    </div>")
    return """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN" lang="zh-CN">
<head>
  <meta charset="utf-8"/>
  <title>%s</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
  %s
</body>
</html>
""" % (html.escape(chapter_title), "\n".join(parts))


def make_epub(book):
    cover = draw_cover(book)
    uid = "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_DNS, "easyread.sample." + book["file"]))
    chapters = []
    for ch in book["chapters"]:
        if ch[1] and isinstance(ch[1][0], tuple):
            chapters.append((ch[0], poem_doc(ch[0], ch[1])))
        else:
            chapters.append((ch[0], chapter_doc(ch[0], ch[1])))
    manifest = [
        '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
        '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
        '    <item id="css" href="style.css" media-type="text/css"/>',
        '    <item id="cover-image" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>',
        '    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>',
    ]
    spine = ['    <itemref idref="cover"/>']
    nav_items = []
    for i, (title, _) in enumerate(chapters, 1):
        manifest.append(f'    <item id="ch{i}" href="ch{i}.xhtml" media-type="application/xhtml+xml"/>')
        spine.append(f'    <itemref idref="ch{i}"/>')
        nav_items.append(f'        <li><a href="ch{i}.xhtml">{html.escape(title)}</a></li>')
    opf = f"""<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="zh-CN">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">{uid}</dc:identifier>
    <dc:title>{html.escape(book["title"])}</dc:title>
    <dc:creator>{html.escape(book["author"])}</dc:creator>
    <dc:language>zh-CN</dc:language>
    <dc:publisher>EasyRead 样章</dc:publisher>
    <dc:description>{html.escape(book["genre"])}，公有领域中文作品，用于阅读器功能展示。</dc:description>
    <meta property="dcterms:modified">2026-11-18T00:00:00Z</meta>
    <meta name="cover" content="cover-image"/>
  </metadata>
  <manifest>
{os.linesep.join(manifest)}
  </manifest>
  <spine toc="ncx">
{os.linesep.join(spine)}
  </spine>
</package>
"""
    nav = f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh-CN" lang="zh-CN">
<head><meta charset="utf-8"/><title>目录</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>目录</h1>
    <ol>
{os.linesep.join(nav_items)}
    </ol>
  </nav>
</body>
</html>
"""
    nav_points = []
    for i, (title, _) in enumerate(chapters, 1):
        nav_points.append(f"""    <navPoint id="np{i}" playOrder="{i}">
      <navLabel><text>{html.escape(title)}</text></navLabel>
      <content src="ch{i}.xhtml"/>
    </navPoint>""")
    ncx = f"""<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="{uid}"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>{html.escape(book["title"])}</text></docTitle>
  <navMap>
{os.linesep.join(nav_points)}
  </navMap>
</ncx>
"""
    cover_xhtml = f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN" lang="zh-CN">
<head><meta charset="utf-8"/><title>封面</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
<body class="cover-page">
  <div class="cover-wrap"><img src="cover.jpg" alt="{html.escape(book["title"])}"/></div>
</body>
</html>
"""
    css = """body { margin: 0; padding: 0; color: #2b2b2b; background: #faf7f0; }
h1 { font-size: 1.6em; font-weight: normal; letter-spacing: 0.12em; margin: 1.2em 0 1.6em; }
h2 { font-size: 1.25em; font-weight: normal; letter-spacing: 0.08em; margin: 1.8em 0 0.5em; }
p { font-size: 1em; line-height: 1.9; text-indent: 2em; margin: 0 0 0.85em; }
.poem { margin: 0 0 2em; }
.poem .author { text-indent: 0; text-align: center; font-size: 0.85em; color: #7a6a55; margin: 0 0 0.9em; }
.poem .verse { text-indent: 0; text-align: center; margin: 0 0 0.35em; line-height: 1.8; }
.cover-page { background: #f3ece0; }
.cover-wrap { text-align: center; margin: 0; padding: 0; }
.cover-wrap img { max-width: 100%; max-height: 100%; }
"""
    container = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""
    out = os.path.join(BASE, book["file"] + ".epub")
    with zipfile.ZipFile(out, "w") as z:
        z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/toc.ncx", ncx, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/style.css", css, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/cover.xhtml", cover_xhtml, compress_type=zipfile.ZIP_DEFLATED)
        with open(cover, "rb") as f:
            z.writestr("OEBPS/cover.jpg", f.read(), compress_type=zipfile.ZIP_DEFLATED)
        for i, (title, doc) in enumerate(chapters, 1):
            z.writestr(f"OEBPS/ch{i}.xhtml", doc, compress_type=zipfile.ZIP_DEFLATED)
    print("wrote", out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    for b in BOOKS:
        make_epub(b)
