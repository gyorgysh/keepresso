# -*- coding: utf-8 -*-
"""Quit modal, machine-aware copy, and quit-behavior disclosure strings."""

APP = {
    "Did you forget to turn it off?": {
        "hu": "Elfelejtette kikapcsolni?", "es": "¿Olvidaste desactivarlo?", "fr": "Avez-vous oublié de le désactiver ?", "de": "Hast du vergessen, es auszuschalten?", "zh-Hans": "忘记把它关掉了吗？",
        "it": "Hai dimenticato di spegnerlo?", "ja": "オフにするのを忘れていませんか？", "ko": "끄는 것을 잊으셨나요?", "ru": "Вы забыли его выключить?", "pt-BR": "Esqueceu de desligar?", "tr": "Kapatmayı mı unuttun?", "pl": "Zapomniałeś to wyłączyć?", "uk": "Забув це вимкнути?", "zh-Hant": "忘記關閉了嗎？",
    },
    "Quit while still brewing?": {
        "hu": "Kilépés főzés közben?", "es": "¿Salir mientras sigue en marcha?", "fr": "Quitter pendant l’infusion ?", "de": "Beim Brühen beenden?", "zh-Hans": "在仍在运行时退出？",
        "it": "Esci mentre è ancora in infusione?", "ja": "抽出中に終了しますか？", "ko": "아직 실행 중인데 종료하시겠습니까?", "ru": "Завершить, пока заваривание продолжается?", "pt-BR": "Sair enquanto ainda está em execução?", "tr": "Hâlâ demlenirken çıkılsın mı?", "pl": "Zamknąć mimo trwającego parzenia?", "uk": "Вийти, коли ще заварюється?", "zh-Hant": "仍在執行中要結束嗎？",
    },
    "Turn off and quit": {
        "hu": "Kikapcsolás és kilépés", "es": "Desactivar y salir", "fr": "Désactiver et quitter", "de": "Ausschalten und beenden", "zh-Hans": "关闭并退出",
        "it": "Spegni ed esci", "ja": "オフにして終了", "ko": "끄고 종료", "ru": "Выключить и завершить", "pt-BR": "Desligar e sair", "tr": "Kapat ve çık", "pl": "Wyłącz i zamknij", "uk": "Вимкнути й вийти", "zh-Hant": "關閉並結束",
    },
    "Quit anyway": {
        "hu": "Kilépés mindenképp", "es": "Salir de todos modos", "fr": "Quitter quand même", "de": "Trotzdem beenden", "zh-Hans": "仍要退出",
        "it": "Esci comunque", "ja": "このまま終了", "ko": "그래도 종료", "ru": "Всё равно завершить", "pt-BR": "Sair mesmo assim", "tr": "Yine de çık", "pl": "Zamknij mimo to", "uk": "Все одно вийти", "zh-Hant": "仍要結束",
    },
    "Stop brewing and quit": {
        "hu": "A főzés leállítása és kilépés", "es": "Detener la marcha y salir", "fr": "Arrêter l’infusion et quitter", "de": "Brühen stoppen und beenden", "zh-Hans": "停止运行并退出",
        "it": "Ferma l'infusione ed esci", "ja": "抽出を停止して終了", "ko": "실행을 중지하고 종료", "ru": "Остановить заваривание и завершить", "pt-BR": "Parar e sair", "tr": "Demlemeyi durdur ve çık", "pl": "Przerwij parzenie i zamknij", "uk": "Зупинити заварювання й вийти", "zh-Hant": "停止執行並結束",
    },
    "A keep-awake session is still brewing. Quitting stops it now instead of at its timer.": {
        "hu": "Egy ébrentartási munkamenet még főz. A kilépés most állítja le, nem az időzítő lejártakor.", "es": "Una sesión sigue en marcha. Salir la detiene ahora en lugar de esperar a su temporizador.", "fr": "Une session est toujours en cours d’infusion. Quitter l’arrête maintenant au lieu d’attendre son minuteur.", "de": "Eine Wachhalte-Sitzung brüht noch. Beenden stoppt sie jetzt statt erst bei ihrem Timer.", "zh-Hans": "一个保持唤醒会话仍在运行中。现在退出会立即停止它，而不是等到计时结束。",
        "it": "Una sessione di veglia è ancora in infusione. Uscire la interrompe ora invece che al suo timer.", "ja": "スリープ防止セッションがまだ抽出中です。終了すると、タイマーではなく今すぐ停止します。", "ko": "깨어 있게 유지 세션이 아직 실행 중입니다. 종료하면 타이머가 끝날 때까지 기다리지 않고 지금 중지됩니다.", "ru": "Сеанс поддержания активности всё ещё заваривается. Выход остановит его сейчас, а не по таймеру.", "pt-BR": "Uma sessão de vigília ainda está em preparo. Sair a interrompe agora em vez de aguardar o timer.", "tr": "Bir uyanık tutma oturumu hâlâ demleniyor. Çıkmak, zamanlayıcısını beklemek yerine onu şimdi durdurur.", "pl": "Sesja czuwania wciąż się parzy. Zakończenie przerywa ją teraz zamiast czekać na licznik czasu.", "uk": "Сеанс підтримки активності ще заварюється. Вихід зупиняє його зараз замість очікування таймера.", "zh-Hant": "保持喚醒工作階段仍在運作中。結束會立即停止它，而不等計時器結束。",
    },
    "%@ would stay awake with the lid shut and nothing managing it.": {
        "hu": "%@ csukott fedéllel is ébren maradna, és semmi sem tartaná ébren.", "es": "%@ seguiría despierto con la tapa cerrada y sin nada que lo mantenga.", "fr": "%@ resterait éveillé capot fermé sans rien pour le maintenir éveillé.", "de": "%@ würde bei geschlossenem Deckel wach bleiben, ohne dass etwas es wach hält.", "zh-Hans": "%@ 会在合盖且没有任何因素管理时保持唤醒。",
        "it": "%@ rimarrebbe sveglio con il coperchio chiuso senza che nulla lo gestisca.", "ja": "%@ は蓋を閉じたままスリープ防止状態になりますが、管理するものは何もありません。", "ko": "%@는 덮개를 닫은 채로 깨어 있게 유지되며, 관리하는 항목이 없습니다.", "ru": "%@ останется активным с закрытой крышкой без какого-либо управления.", "pt-BR": "%@ ficaria ativo com a tampa fechada e sem nada o gerenciando.", "tr": "%@, kapak kapalıyken ve onu yöneten hiçbir şey yokken uyanık kalırdı.", "pl": "%@ pozostałby aktywny przy zamkniętej pokrywie, gdyby nic nim nie zarządzało.", "uk": "%@ залишався б активним із закритою кришкою без жодного керування.", "zh-Hant": "%@ 會在合蓋且無任何項目管理的情況下保持喚醒。",
    },
    "%@ would stay awake with the lid shut and nothing managing it, %@.": {
        "hu": "%@ csukott fedéllel is ébren maradna, és semmi sem tartaná ébren, %@.", "es": "%@ seguiría despierto con la tapa cerrada y sin nada que lo mantenga, %@.", "fr": "%@ resterait éveillé capot fermé sans rien pour le maintenir éveillé, %@.", "de": "%@ würde bei geschlossenem Deckel wach bleiben, ohne dass etwas es wach hält, %@.", "zh-Hans": "%@ 会在合盖且没有任何因素管理时保持唤醒，%@。",
        "it": "%@ rimarrebbe sveglio con il coperchio chiuso senza che nulla lo gestisca, %@.", "ja": "%@ は蓋を閉じたままスリープ防止状態になりますが、管理するものは何もありません（%@）。", "ko": "%@는 덮개를 닫은 채로 깨어 있게 유지되며, 관리하는 항목이 없습니다(%@).", "ru": "%@ останется активным с закрытой крышкой без какого-либо управления (%@).", "pt-BR": "%@ ficaria ativo com a tampa fechada e sem nada o gerenciando, %@.", "tr": "%@, kapak kapalıyken ve onu yöneten hiçbir şey yokken uyanık kalırdı, %@.", "pl": "%@ pozostałby aktywny przy zamkniętej pokrywie, gdyby nic nim nie zarządzało, %@.", "uk": "%@ залишався б активним із закритою кришкою без жодного керування, %@.", "zh-Hant": "%@ 會在合蓋且無任何項目管理的情況下保持喚醒，%@。",
    },
    "Turn this on and then quit, and Keepresso asks whether to turn it off first.": {
        "hu": "Kapcsolja be ezt, majd lépjen ki, és a Keepresso megkérdezi, hogy előbb kikapcsolja-e.", "es": "Activa esto y luego sal, y Keepresso preguntará si debe desactivarlo primero.", "fr": "Activez ceci puis quittez, et Keepresso demandera ensuite s’il faut d’abord le désactiver.", "de": "Schalte dies ein und beende dann, und Keepresso fragt, ob es zuerst ausgeschaltet werden soll.", "zh-Hans": "先开启此项再退出，Keepresso 会询问是否先将其关闭。",
        "it": "Attiva questa opzione e poi esci: Keepresso chiederà se disattivarla prima.", "ja": "これをオンにしてから終了すると、Keepresso が先にオフにするかどうかを確認します。", "ko": "이것을 켜고 종료하면 Keepresso가 먼저 끌지 여부를 묻습니다.", "ru": "Включите это, а затем завершите работу: Keepresso спросит, нужно ли сначала его выключить.", "pt-BR": "Ative isto e depois saia, e o Keepresso pergunta se deve desligar antes.", "tr": "Bunu açıp sonra çık, Keepresso önce kapatıp kapatmayacağını sorar.", "pl": "Włącz to, a potem zamknij, a Keepresso najpierw zapyta, czy to wyłączyć.", "uk": "Увімкни це, а потім вийди, і Keepresso спочатку запитає, чи вимкнути це.", "zh-Hant": "開啟此項後再結束，Keepresso 會先詢問是否要將其關閉。",
    },
}

CORE = {
    "your %@": {
        "hu": "az Ön %@", "es": "tu %@", "fr": "votre %@", "de": "dein %@", "zh-Hans": "你的 %@",
        "it": "il tuo %@", "ja": "あなたの %@", "ko": "사용자의 %@", "ru": "ваш %@", "pt-BR": "seu %@", "tr": "senin %@", "pl": "twój %@", "uk": "твій %@", "zh-Hant": "你的 %@",
    },
    "on battery": {
        "hu": "akkumulátorról", "es": "con batería", "fr": "sur batterie", "de": "im Akkubetrieb", "zh-Hans": "使用电池时",
        "it": "A batteria", "ja": "バッテリー使用時", "ko": "배터리 사용 시", "ru": "От аккумулятора", "pt-BR": "na bateria", "tr": "pilde", "pl": "na baterii", "uk": "від акумулятора", "zh-Hant": "使用電池時",
    },
    "on battery at %d%%": {
        "hu": "akkumulátorról %d%%-nál", "es": "con batería al %d%%", "fr": "sur batterie à %d%%", "de": "im Akkubetrieb bei %d%%", "zh-Hans": "使用电池且电量为 %d%% 时",
        "it": "A batteria al %d%%", "ja": "バッテリー使用時（残量 %d%%）", "ko": "배터리 사용 시 %d%%", "ru": "От аккумулятора, заряд %d%%", "pt-BR": "na bateria com %d%%", "tr": "pilde, %d%% seviyesinde", "pl": "na baterii przy %d%%", "uk": "від акумулятора на %d%%", "zh-Hant": "使用電池，電量為 %d%%",
    },
}
