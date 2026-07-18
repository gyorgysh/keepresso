# -*- coding: utf-8 -*-
"""Main-language strings introduced by the AI power orchestration work.

Keys map to translations for the five languages stored inline in Keepresso's
main catalogs. This overlay is intentionally separate so parallel translation
work can be reviewed and merged without touching the generated strings files.
"""

import re


LANGUAGES = ("hu", "es", "fr", "de", "zh-Hans")


APP = {
    "%d active Agent lease(s)": {
        "hu": "Aktív ügynöki ébrentartási bérletek: %d",
        "es": "Leases activos de agentes para mantener el Mac despierto: %d",
        "fr": "Baux d’éveil d’agents actifs : %d",
        "de": "Aktive Agent-Wachhalte-Leases: %d",
        "zh-Hans": "%d 个活跃的代理唤醒租约",
    },
    "%d active local automation(s)": {
        "hu": "Aktív helyi automatizálások: %d",
        "es": "Automatizaciones locales activas: %d",
        "fr": "Automatisations locales actives : %d",
        "de": "Aktive lokale Automatisierungen: %d",
        "zh-Hans": "%d 个活跃的本地自动化",
    },
    "%d automation file(s) could not be used": {
        "hu": "%d automatizálási fájl nem használható",
        "es": "No se pudieron usar %d archivos de automatización",
        "fr": "%d fichiers d’automatisation n’ont pas pu être utilisés",
        "de": "%d Automatisierungsdateien konnten nicht verwendet werden",
        "zh-Hans": "%d 个自动化文件无法使用",
    },
    "%d%%": {
        "hu": "%d%%",
        "es": "%d%%",
        "fr": "%d %%",
        "de": "%d %%",
        "zh-Hans": "%d%%",
    },
    "+%d more Agent lease(s)": {
        "hu": "+%d további ügynöki ébrentartási bérlet",
        "es": "+%d leases de agente más para mantener el Mac despierto",
        "fr": "+%d baux d’éveil d’agent supplémentaires",
        "de": "+%d weitere Agent-Wachhalte-Leases",
        "zh-Hans": "另有 %d 个代理唤醒租约",
    },
    "20 minutes": {
        "hu": "20 perc",
        "es": "20 minutos",
        "fr": "20 minutes",
        "de": "20 Minuten",
        "zh-Hans": "20 分钟",
    },
    "After all unattended work": {
        "hu": "Minden felügyelet nélküli munka után",
        "es": "Tras finalizar todo el trabajo sin supervisión",
        "fr": "Après tous les travaux sans surveillance",
        "de": "Nach allen unbeaufsichtigten Aufgaben",
        "zh-Hans": "所有无人值守任务结束后",
    },
    "Agent and unattended log": {
        "hu": "Ügynöki és felügyelet nélküli események naplója",
        "es": "Registro de agentes y trabajo sin supervisión",
        "fr": "Journal des agents et travaux sans surveillance",
        "de": "Protokoll für Agenten und unbeaufsichtigte Aufgaben",
        "zh-Hans": "代理与无人值守日志",
    },
    "Agent lease: %@": {
        "hu": "Ügynöki ébrentartási bérlet: %@",
        "es": "Lease de agente para mantener el Mac despierto: %@",
        "fr": "Bail d’éveil d’agent : %@",
        "de": "Agent-Wachhalte-Lease: %@",
        "zh-Hans": "代理唤醒租约：%@",
    },
    "Agent wake lease expired": {
        "hu": "Lejárt az ügynök ébrentartási bérlete",
        "es": "Caducó el lease del agente para mantener el Mac despierto",
        "fr": "Le bail d’éveil de l’agent a expiré",
        "de": "Agent-Wachhalte-Lease abgelaufen",
        "zh-Hans": "代理唤醒租约已过期",
    },
    "Agent work owns keep-awake until every lease and scheduled handoff finishes.": {
        "hu": "Az ügynöki munka addig tartja ébren a Macet, amíg minden bérlet és ütemezett átadás be nem fejeződik.",
        "es": "El trabajo de los agentes mantiene el Mac despierto hasta que terminen todos los leases y traspasos programados.",
        "fr": "Le travail des agents garde le Mac éveillé jusqu’à la fin de tous les baux et transferts planifiés.",
        "de": "Agent-Aufgaben halten den Mac wach, bis alle Leases und geplanten Übergaben beendet sind.",
        "zh-Hans": "代理任务会保持 Mac 唤醒，直到所有租约和计划交接都结束。",
    },
    "An Agent stopped renewing its lease. Keepresso released that task's wake request safely.": {
        "hu": "Egy ügynök nem újította meg a bérletét. A Keepresso biztonságosan feloldotta a feladat ébrentartási kérését.",
        "es": "Un agente dejó de renovar su lease. Keepresso liberó de forma segura la solicitud de esa tarea para mantener el Mac despierto.",
        "fr": "Un agent a cessé de renouveler son bail. Keepresso a libéré en toute sécurité la demande d’éveil de cette tâche.",
        "de": "Ein Agent hat sein Lease nicht mehr verlängert. Keepresso hat die Wachhalteanforderung der Aufgabe sicher freigegeben.",
        "zh-Hans": "一个代理停止续租。Keepresso 已安全释放该任务的唤醒请求。",
    },
    "Automation prompt text is discarded during parsing and is never retained, displayed, or logged. Configure the Keepresso Skill or MCP server so each Agent acquires, renews, and releases its own lease.": {
        "hu": "Az automatizálás utasításszövege az elemzés során törlődik, és soha nem lesz megőrizve, megjelenítve vagy naplózva. Állítsa be a Keepresso Skillt vagy az MCP-kiszolgálót, hogy minden ügynök saját bérletet kérjen, újítson meg és engedjen el.",
        "es": "El texto de las instrucciones de automatización se descarta durante el análisis y nunca se conserva, muestra ni registra. Configura la Skill de Keepresso o el servidor MCP para que cada agente adquiera, renueve y libere su propio lease.",
        "fr": "Le texte des instructions d’automatisation est supprimé pendant l’analyse et n’est jamais conservé, affiché ni journalisé. Configurez la Skill Keepresso ou le serveur MCP afin que chaque agent acquière, renouvelle et libère son propre bail.",
        "de": "Der Anweisungstext der Automatisierung wird beim Einlesen verworfen und niemals gespeichert, angezeigt oder protokolliert. Richte den Keepresso Skill oder MCP-Server so ein, dass jeder Agent sein eigenes Lease anfordert, verlängert und freigibt.",
        "zh-Hans": "解析时会丢弃自动化提示词，绝不会保留、显示或记录。请配置 Keepresso Skill 或 MCP 服务器，让每个代理自行申请、续租和释放租约。",
    },
    "Automation discovery completed": {
        "hu": "Az automatizálások felderítése befejeződött",
        "es": "Finalizó la detección de automatizaciones",
        "fr": "Détection des automatisations terminée",
        "de": "Automatisierungssuche abgeschlossen",
        "zh-Hans": "自动化发现已完成",
    },
    "Automation discovery failed": {
        "hu": "Az automatizálások felderítése sikertelen",
        "es": "Falló la detección de automatizaciones",
        "fr": "Échec de la détection des automatisations",
        "de": "Automatisierungssuche fehlgeschlagen",
        "zh-Hans": "自动化发现失败",
    },
    "Closed-lid protection needs the administrator helper.": {
        "hu": "A csukott fedeles védelemhez rendszergazdai segéd szükséges.",
        "es": "La protección con la tapa cerrada necesita el asistente de administrador.",
        "fr": "La protection capot fermé nécessite l’assistant administrateur.",
        "de": "Der Schutz bei geschlossenem Deckel benötigt den Administrator-Hilfsdienst.",
        "zh-Hans": "合盖保护需要管理员助理。",
    },
    "Codex automation did not claim a wake lease": {
        "hu": "A Codex-automatizálás nem kért ébrentartási bérletet",
        "es": "La automatización de Codex no solicitó un lease para mantener el Mac despierto",
        "fr": "L’automatisation Codex n’a pas demandé de bail d’éveil",
        "de": "Codex-Automatisierung hat kein Wachhalte-Lease angefordert",
        "zh-Hans": "Codex 自动化未申请唤醒租约",
    },
    "Codex automation idle": {
        "hu": "A Codex-automatizálás tétlen",
        "es": "Automatización de Codex inactiva",
        "fr": "Automatisation Codex inactive",
        "de": "Codex-Automatisierung inaktiv",
        "zh-Hans": "Codex 自动化空闲",
    },
    "Codex automation needs the administrator helper": {
        "hu": "A Codex-automatizáláshoz rendszergazdai segéd szükséges",
        "es": "La automatización de Codex necesita el asistente de administrador",
        "fr": "L’automatisation Codex nécessite l’assistant administrateur",
        "de": "Codex-Automatisierung benötigt den Administrator-Hilfsdienst",
        "zh-Hans": "Codex 自动化需要管理员助理",
    },
    "Codex automation preparation": {
        "hu": "Codex-automatizálás előkészítése",
        "es": "Preparación de la automatización de Codex",
        "fr": "Préparation de l’automatisation Codex",
        "de": "Codex-Automatisierung wird vorbereitet",
        "zh-Hans": "正在准备 Codex 自动化",
    },
    "Codex automation readiness failed": {
        "hu": "A Codex-automatizálás előkészítése sikertelen",
        "es": "Falló la preparación de la automatización de Codex",
        "fr": "Échec de la préparation de l’automatisation Codex",
        "de": "Bereitschaft für Codex-Automatisierung fehlgeschlagen",
        "zh-Hans": "Codex 自动化就绪检查失败",
    },
    "Codex automation wake": {
        "hu": "Ébresztés Codex-automatizáláshoz",
        "es": "Despertar para automatizaciones de Codex",
        "fr": "Réveil pour les automatisations Codex",
        "de": "Aufwecken für Codex-Automatisierungen",
        "zh-Hans": "Codex 自动化唤醒",
    },
    "Codex automation wake is saved but inactive until the administrator helper is ready.": {
        "hu": "A Codex-automatizálás ébresztése mentve van, de a rendszergazdai segéd elkészültéig inaktív.",
        "es": "El despertar para automatizaciones de Codex está guardado, pero permanecerá inactivo hasta que el asistente de administrador esté listo.",
        "fr": "Le réveil pour les automatisations Codex est enregistré, mais reste inactif tant que l’assistant administrateur n’est pas prêt.",
        "de": "Das Aufwecken für Codex-Automatisierungen ist gespeichert, bleibt aber inaktiv, bis der Administrator-Hilfsdienst bereit ist.",
        "zh-Hans": "Codex 自动化唤醒已保存，但在管理员助理就绪前不会生效。",
    },
    "Codex automation was not started": {
        "hu": "A Codex-automatizálás nem indult el",
        "es": "La automatización de Codex no se inició",
        "fr": "L’automatisation Codex n’a pas démarré",
        "de": "Codex-Automatisierung wurde nicht gestartet",
        "zh-Hans": "Codex 自动化未启动",
    },
    "Follow local Codex automations": {
        "hu": "Helyi Codex-automatizálások követése",
        "es": "Seguir las automatizaciones locales de Codex",
        "fr": "Suivre les automatisations Codex locales",
        "de": "Lokalen Codex-Automatisierungen folgen",
        "zh-Hans": "跟随本地 Codex 自动化",
    },
    "Held by %d Agent lease(s)": {
        "hu": "%d ügynöki ébrentartási bérlet tartja ébren",
        "es": "%d leases de agente mantienen el Mac despierto",
        "fr": "Maintien par %d baux d’éveil d’agent",
        "de": "Von %d Agent-Wachhalte-Leases gehalten",
        "zh-Hans": "%d 个代理唤醒租约正在保持 Mac 唤醒",
    },
    "Install and approve the helper before relying on unattended wake or closed-lid work.": {
        "hu": "Telepítse és hagyja jóvá a segédet, mielőtt felügyelet nélküli ébresztésre vagy csukott fedeles munkára hagyatkozna.",
        "es": "Instala y aprueba el asistente antes de confiar en el despertar sin supervisión o el trabajo con la tapa cerrada.",
        "fr": "Installez et approuvez l’assistant avant de compter sur un réveil sans surveillance ou un travail capot fermé.",
        "de": "Installiere und genehmige den Hilfsdienst, bevor du dich auf unbeaufsichtigtes Aufwecken oder Arbeiten bei geschlossenem Deckel verlässt.",
        "zh-Hans": "请先安装并批准助理，再依赖无人值守唤醒或合盖运行。",
    },
    "Keepresso extracts only scheduling metadata from enabled local Codex automations. It wakes the Mac before the nearest run, waits for power, battery, network, and the Codex app, then holds the Mac until the Agent acquires an explicit lease or the handoff times out.": {
        "hu": "A Keepresso csak az engedélyezett helyi Codex-automatizálások ütemezési metaadatait olvassa ki. A legközelebbi futás előtt felébreszti a Macet, megvárja a tápellátás, az akkumulátor, a hálózat és a Codex alkalmazás készenlétét, majd ébren tartja a Macet, amíg az ügynök kifejezett bérletet nem kér, vagy az átadási idő le nem jár.",
        "es": "Keepresso solo extrae los metadatos de programación de las automatizaciones locales de Codex activadas. Despierta el Mac antes de la ejecución más próxima, espera a que estén listos la alimentación, la batería, la red y la app Codex, y mantiene el Mac despierto hasta que el agente adquiere un lease explícito o vence el traspaso.",
        "fr": "Keepresso extrait uniquement les métadonnées de planification des automatisations Codex locales activées. Il réveille le Mac avant la prochaine exécution, attend que l’alimentation, la batterie, le réseau et l’app Codex soient prêts, puis garde le Mac éveillé jusqu’à ce que l’agent acquière un bail explicite ou que le transfert expire.",
        "de": "Keepresso liest nur die Planungsmetadaten aktivierter lokaler Codex-Automatisierungen. Es weckt den Mac vor dem nächsten Lauf, wartet auf Stromversorgung, Akku, Netzwerk und die Codex-App und hält den Mac dann wach, bis der Agent ein ausdrückliches Lease anfordert oder die Übergabe abläuft.",
        "zh-Hans": "Keepresso 只提取已启用的本地 Codex 自动化中的计划元数据。它会在最近一次运行前唤醒 Mac，等待电源、电池、网络和 Codex App 就绪，然后保持 Mac 唤醒，直到代理明确申请租约或交接超时。",
    },
    "Keepresso released the expired handoff requests. Any Agent leases still active remain protected.": {
        "hu": "A Keepresso feloldotta a lejárt átadási kéréseket. A még aktív ügynöki bérletek továbbra is védettek.",
        "es": "Keepresso liberó las solicitudes de traspaso caducadas. Los leases de agentes que sigan activos permanecen protegidos.",
        "fr": "Keepresso a libéré les demandes de transfert expirées. Les baux d’agents encore actifs restent protégés.",
        "de": "Keepresso hat die abgelaufenen Übergabeanforderungen freigegeben. Noch aktive Agent-Leases bleiben geschützt.",
        "zh-Hans": "Keepresso 已释放过期的交接请求。仍然活跃的代理租约会继续受到保护。",
    },
    "Lease acquired": {
        "hu": "Bérlet megszerezve",
        "es": "Lease adquirido",
        "fr": "Bail acquis",
        "de": "Lease erworben",
        "zh-Hans": "已申请租约",
    },
    "Lease changed by another process": {
        "hu": "A bérletet egy másik folyamat módosította",
        "es": "Otro proceso modificó el lease",
        "fr": "Bail modifié par un autre processus",
        "de": "Lease von einem anderen Prozess geändert",
        "zh-Hans": "租约已被其他进程更改",
    },
    "Lease heartbeat received": {
        "hu": "A bérlet életjelzése megérkezett",
        "es": "Se recibió la señal de actividad del lease",
        "fr": "Signal de vie du bail reçu",
        "de": "Lease-Heartbeat empfangen",
        "zh-Hans": "已收到租约心跳",
    },
    "Lease released": {
        "hu": "Bérlet feloldva",
        "es": "Lease liberado",
        "fr": "Bail libéré",
        "de": "Lease freigegeben",
        "zh-Hans": "租约已释放",
    },
    "Lease renewed": {
        "hu": "Bérlet megújítva",
        "es": "Lease renovado",
        "fr": "Bail renouvelé",
        "de": "Lease verlängert",
        "zh-Hans": "租约已续期",
    },
    "Lease restored after restart": {
        "hu": "Bérlet visszaállítva újraindítás után",
        "es": "Lease restaurado tras reiniciar",
        "fr": "Bail restauré après redémarrage",
        "de": "Lease nach Neustart wiederhergestellt",
        "zh-Hans": "租约已在重启后恢复",
    },
    "Lease timed out": {
        "hu": "A bérlet időkorlátja lejárt",
        "es": "Se agotó el tiempo del lease",
        "fr": "Délai du bail expiré",
        "de": "Zeitlimit des Leases abgelaufen",
        "zh-Hans": "租约已超时",
    },
    "Lock screen before unattended work": {
        "hu": "Képernyő zárolása felügyelet nélküli munka előtt",
        "es": "Bloquear la pantalla antes del trabajo sin supervisión",
        "fr": "Verrouiller l’écran avant le travail sans surveillance",
        "de": "Bildschirm vor unbeaufsichtigter Arbeit sperren",
        "zh-Hans": "无人值守任务前锁定屏幕",
    },
    "MCP server": {
        "hu": "MCP-kiszolgáló",
        "es": "Servidor MCP",
        "fr": "Serveur MCP",
        "de": "MCP-Server",
        "zh-Hans": "MCP 服务器",
    },
    "Minimum battery": {
        "hu": "Minimális akkumulátortöltöttség",
        "es": "Batería mínima",
        "fr": "Niveau de batterie minimal",
        "de": "Mindestakkustand",
        "zh-Hans": "最低电量",
    },
    "Next run: %@": {
        "hu": "Következő futás: %@",
        "es": "Próxima ejecución: %@",
        "fr": "Prochaine exécution : %@",
        "de": "Nächster Lauf: %@",
        "zh-Hans": "下次运行：%@",
    },
    "Next wake: %@": {
        "hu": "Következő ébresztés: %@",
        "es": "Próximo despertar: %@",
        "fr": "Prochain réveil : %@",
        "de": "Nächstes Aufwecken: %@",
        "zh-Hans": "下次唤醒：%@",
    },
    "No Agent or unattended activity yet.": {
        "hu": "Még nincs ügynöki vagy felügyelet nélküli tevékenység.",
        "es": "Aún no hay actividad de agentes ni trabajo sin supervisión.",
        "fr": "Aucune activité d’agent ni tâche sans surveillance pour le moment.",
        "de": "Noch keine Agent-Aktivität oder unbeaufsichtigte Arbeit.",
        "zh-Hans": "暂无代理或无人值守活动。",
    },
    "No enabled local Codex automation found": {
        "hu": "Nem található engedélyezett helyi Codex-automatizálás",
        "es": "No se encontró ninguna automatización local de Codex activada",
        "fr": "Aucune automatisation Codex locale activée trouvée",
        "de": "Keine aktivierte lokale Codex-Automatisierung gefunden",
        "zh-Hans": "未找到已启用的本地 Codex 自动化",
    },
    "Opening Codex": {
        "hu": "A Codex megnyitása",
        "es": "Abriendo Codex",
        "fr": "Ouverture de Codex",
        "de": "Codex wird geöffnet",
        "zh-Hans": "正在打开 Codex",
    },
    "Power, network, or the Codex application did not become ready in time.": {
        "hu": "A tápellátás, a hálózat vagy a Codex alkalmazás nem készült el időben.",
        "es": "La alimentación, la red o la aplicación Codex no estuvieron listas a tiempo.",
        "fr": "L’alimentation, le réseau ou l’application Codex n’étaient pas prêts à temps.",
        "de": "Stromversorgung, Netzwerk oder Codex-Anwendung waren nicht rechtzeitig bereit.",
        "zh-Hans": "电源、网络或 Codex 应用未能及时就绪。",
    },
    "Preparation window is open now": {
        "hu": "Az előkészítési időablak már nyitva van",
        "es": "El periodo de preparación ya está abierto",
        "fr": "La fenêtre de préparation est ouverte",
        "de": "Das Vorbereitungsfenster ist jetzt geöffnet",
        "zh-Hans": "当前已进入准备时间窗口",
    },
    "Readiness timeout": {
        "hu": "Készenléti időkorlát",
        "es": "Tiempo límite de preparación",
        "fr": "Délai de préparation",
        "de": "Bereitschaftszeitlimit",
        "zh-Hans": "就绪超时",
    },
    "Readiness checks passed": {
        "hu": "A készenléti ellenőrzések sikeresek",
        "es": "Se superaron las comprobaciones de preparación",
        "fr": "Vérifications de préparation réussies",
        "de": "Bereitschaftsprüfungen bestanden",
        "zh-Hans": "就绪检查已通过",
    },
    "Readiness retry scheduled": {
        "hu": "Készenléti újrapróbálkozás ütemezve",
        "es": "Se programó un nuevo intento de preparación",
        "fr": "Nouvelle tentative de préparation planifiée",
        "de": "Erneute Bereitschaftsprüfung geplant",
        "zh-Hans": "已计划重试就绪检查",
    },
    "Readiness timed out": {
        "hu": "A készenléti ellenőrzés időkorlátja lejárt",
        "es": "Se agotó el tiempo de preparación",
        "fr": "Délai de préparation expiré",
        "de": "Zeitlimit der Bereitschaftsprüfung abgelaufen",
        "zh-Hans": "就绪检查已超时",
    },
    "Require external power": {
        "hu": "Külső tápellátás megkövetelése",
        "es": "Requerir alimentación externa",
        "fr": "Exiger une alimentation externe",
        "de": "Externe Stromversorgung voraussetzen",
        "zh-Hans": "需要外接电源",
    },
    "Require minimum battery": {
        "hu": "Minimális akkumulátortöltöttség megkövetelése",
        "es": "Requerir un nivel mínimo de batería",
        "fr": "Exiger un niveau de batterie minimal",
        "de": "Mindestakkustand voraussetzen",
        "zh-Hans": "需要最低电量",
    },
    "Require network": {
        "hu": "Hálózat megkövetelése",
        "es": "Requerir conexión de red",
        "fr": "Exiger une connexion réseau",
        "de": "Netzwerk voraussetzen",
        "zh-Hans": "需要网络",
    },
    "Reveal Keepresso Agent Skill": {
        "hu": "A Keepresso ügynöki Skill megjelenítése",
        "es": "Mostrar la Skill de agentes de Keepresso",
        "fr": "Afficher la Skill d’agent Keepresso",
        "de": "Keepresso Agent Skill im Finder zeigen",
        "zh-Hans": "显示 Keepresso 代理 Skill",
    },
    "Scheduled Agent lease active": {
        "hu": "Az ütemezett ügynöki bérlet aktív",
        "es": "Lease de agente programado activo",
        "fr": "Bail d’agent planifié actif",
        "de": "Geplantes Agent-Lease aktiv",
        "zh-Hans": "计划代理租约已生效",
    },
    "Scheduled and Agent-driven jobs use a separate secure policy. By default Keepresso locks the login session, turns off the display while preserving the system assertion, and sleeps the Mac after the final job finishes.": {
        "hu": "Az ütemezett és ügynök által vezérelt feladatok külön biztonsági házirendet használnak. A Keepresso alapértelmezés szerint zárolja a bejelentkezési munkamenetet, kikapcsolja a kijelzőt a rendszer ébren tartása mellett, és az utolsó feladat befejezése után elaltatja a Macet.",
        "es": "Las tareas programadas y controladas por agentes usan una política de seguridad independiente. De forma predeterminada, Keepresso bloquea la sesión de inicio, apaga la pantalla sin retirar la aserción del sistema y suspende el Mac cuando termina la última tarea.",
        "fr": "Les tâches planifiées et pilotées par des agents utilisent une politique de sécurité distincte. Par défaut, Keepresso verrouille la session, éteint l’écran tout en conservant l’assertion système et met le Mac en veille lorsque la dernière tâche se termine.",
        "de": "Geplante und von Agenten gesteuerte Aufgaben verwenden eine eigene sichere Richtlinie. Standardmäßig sperrt Keepresso die Anmeldesitzung, schaltet das Display aus, ohne die Systemassertion aufzuheben, und versetzt den Mac nach Abschluss der letzten Aufgabe in den Ruhezustand.",
        "zh-Hans": "计划任务和代理驱动的任务使用独立的安全策略。默认情况下，Keepresso 会锁定登录会话，在保留系统唤醒断言的同时关闭显示器，并在最后一个任务结束后让 Mac 进入睡眠。",
    },
    "Some Codex automations did not claim a wake lease": {
        "hu": "Néhány Codex-automatizálás nem kért ébrentartási bérletet",
        "es": "Algunas automatizaciones de Codex no solicitaron un lease para mantener el Mac despierto",
        "fr": "Certaines automatisations Codex n’ont pas demandé de bail d’éveil",
        "de": "Einige Codex-Automatisierungen haben kein Wachhalte-Lease angefordert",
        "zh-Hans": "部分 Codex 自动化未申请唤醒租约",
    },
    "Structured events only, with no automation prompts or command arguments. Saved at %@": {
        "hu": "Csak strukturált események, automatizálási utasítások és parancsargumentumok nélkül. Mentési hely: %@",
        "es": "Solo eventos estructurados, sin instrucciones de automatización ni argumentos de comandos. Guardado en %@",
        "fr": "Uniquement des événements structurés, sans instructions d’automatisation ni arguments de commande. Enregistré dans %@",
        "de": "Nur strukturierte Ereignisse, ohne Automatisierungsanweisungen oder Befehlsargumente. Gespeichert unter %@",
        "zh-Hans": "仅记录结构化事件，不含自动化提示词或命令参数。保存在 %@",
    },
    "System is eligible to sleep": {
        "hu": "A rendszer alvó állapotba léphet",
        "es": "El sistema ya puede entrar en reposo",
        "fr": "Le système peut désormais se mettre en veille",
        "de": "Das System kann jetzt in den Ruhezustand wechseln",
        "zh-Hans": "系统现在可以进入睡眠",
    },
    "The Agent lease registry could not be opened.": {
        "hu": "Az ügynöki ébrentartási bérletek nyilvántartása nem nyitható meg.",
        "es": "No se pudo abrir el registro de leases de agentes.",
        "fr": "Le registre des baux d’agents n’a pas pu être ouvert.",
        "de": "Das Agent-Lease-Register konnte nicht geöffnet werden.",
        "zh-Hans": "无法打开代理租约注册表。",
    },
    "The Agent lease registry could not be read.": {
        "hu": "Az ügynöki ébrentartási bérletek nyilvántartása nem olvasható.",
        "es": "No se pudo leer el registro de leases de agentes.",
        "fr": "Le registre des baux d’agents n’a pas pu être lu.",
        "de": "Das Agent-Lease-Register konnte nicht gelesen werden.",
        "zh-Hans": "无法读取代理租约注册表。",
    },
    "The handoff window expired, so Keepresso restored normal sleep safely.": {
        "hu": "Az átadási időablak lejárt, ezért a Keepresso biztonságosan visszaállította a normál alvást.",
        "es": "Venció el periodo de traspaso, por lo que Keepresso restauró de forma segura el reposo normal.",
        "fr": "La fenêtre de transfert a expiré. Keepresso a donc rétabli la veille normale en toute sécurité.",
        "de": "Das Übergabefenster ist abgelaufen. Keepresso hat den normalen Ruhezustand sicher wiederhergestellt.",
        "zh-Hans": "交接时间窗口已过期，Keepresso 已安全恢复正常睡眠。",
    },
    "These defaults do not change interactive keep-awake sessions.": {
        "hu": "Ezek az alapértékek nem módosítják az interaktív ébrentartási munkameneteket.",
        "es": "Estos valores predeterminados no modifican las sesiones interactivas para mantener el Mac despierto.",
        "fr": "Ces réglages par défaut ne modifient pas les sessions interactives de maintien en éveil.",
        "de": "Diese Standardwerte ändern interaktive Wachhalte-Sitzungen nicht.",
        "zh-Hans": "这些默认设置不会改变交互式保持唤醒会话。",
    },
    "Turn Off Codex Automation Wake": {
        "hu": "Codex-automatizálási ébresztés kikapcsolása",
        "es": "Desactivar el despertar para automatizaciones de Codex",
        "fr": "Désactiver le réveil des automatisations Codex",
        "de": "Aufwecken für Codex-Automatisierungen ausschalten",
        "zh-Hans": "关闭 Codex 自动化唤醒",
    },
    "Turn display off before unattended work": {
        "hu": "Kijelző kikapcsolása felügyelet nélküli munka előtt",
        "es": "Apagar la pantalla antes del trabajo sin supervisión",
        "fr": "Éteindre l’écran avant le travail sans surveillance",
        "de": "Display vor unbeaufsichtigter Arbeit ausschalten",
        "zh-Hans": "无人值守任务前关闭显示器",
    },
    "Unattended Agent work": {
        "hu": "Felügyelet nélküli ügynöki munka",
        "es": "Trabajo de agentes sin supervisión",
        "fr": "Travail d’agents sans surveillance",
        "de": "Unbeaufsichtigte Agent-Aufgaben",
        "zh-Hans": "无人值守代理任务",
    },
    "Unattended event": {
        "hu": "Felügyelet nélküli esemény",
        "es": "Evento sin supervisión",
        "fr": "Événement sans surveillance",
        "de": "Unbeaufsichtigtes Ereignis",
        "zh-Hans": "无人值守事件",
    },
    "Unattended orchestration cancelled": {
        "hu": "A felügyelet nélküli vezérlés megszakítva",
        "es": "Se canceló la coordinación sin supervisión",
        "fr": "Orchestration sans surveillance annulée",
        "de": "Unbeaufsichtigte Orchestrierung abgebrochen",
        "zh-Hans": "无人值守编排已取消",
    },
    "Unattended task cancelled": {
        "hu": "Felügyelet nélküli feladat megszakítva",
        "es": "Tarea sin supervisión cancelada",
        "fr": "Tâche sans surveillance annulée",
        "de": "Unbeaufsichtigte Aufgabe abgebrochen",
        "zh-Hans": "无人值守任务已取消",
    },
    "Unattended task failed": {
        "hu": "A felügyelet nélküli feladat sikertelen",
        "es": "Falló la tarea sin supervisión",
        "fr": "Échec de la tâche sans surveillance",
        "de": "Unbeaufsichtigte Aufgabe fehlgeschlagen",
        "zh-Hans": "无人值守任务失败",
    },
    "Unattended task started": {
        "hu": "A felügyelet nélküli feladat elindult",
        "es": "Comenzó la tarea sin supervisión",
        "fr": "Tâche sans surveillance démarrée",
        "de": "Unbeaufsichtigte Aufgabe gestartet",
        "zh-Hans": "无人值守任务已启动",
    },
    "Unattended task succeeded": {
        "hu": "A felügyelet nélküli feladat sikeresen befejeződött",
        "es": "La tarea sin supervisión finalizó correctamente",
        "fr": "Tâche sans surveillance terminée avec succès",
        "de": "Unbeaufsichtigte Aufgabe erfolgreich abgeschlossen",
        "zh-Hans": "无人值守任务成功完成",
    },
    "Unattended task timed out": {
        "hu": "A felügyelet nélküli feladat időkorlátja lejárt",
        "es": "Se agotó el tiempo de la tarea sin supervisión",
        "fr": "Délai de la tâche sans surveillance expiré",
        "de": "Zeitlimit der unbeaufsichtigten Aufgabe abgelaufen",
        "zh-Hans": "无人值守任务已超时",
    },
    "Unattended work: %@": {
        "hu": "Felügyelet nélküli munka: %@",
        "es": "Trabajo sin supervisión: %@",
        "fr": "Travail sans surveillance : %@",
        "de": "Unbeaufsichtigte Arbeit: %@",
        "zh-Hans": "无人值守任务：%@",
    },
    "Wait for Agent lease": {
        "hu": "Várakozás az ügynöki bérletre",
        "es": "Esperar el lease del agente",
        "fr": "Attendre le bail de l’agent",
        "de": "Auf Agent-Lease warten",
        "zh-Hans": "等待代理租约",
    },
    "Waiting for power, network, and Codex": {
        "hu": "Várakozás a tápellátásra, a hálózatra és a Codexre",
        "es": "Esperando la alimentación, la red y Codex",
        "fr": "En attente de l’alimentation, du réseau et de Codex",
        "de": "Warten auf Stromversorgung, Netzwerk und Codex",
        "zh-Hans": "正在等待电源、网络和 Codex",
    },
    "Waiting for the scheduled Agent lease": {
        "hu": "Várakozás az ütemezett ügynöki bérletre",
        "es": "Esperando el lease de agente programado",
        "fr": "En attente du bail d’agent planifié",
        "de": "Warten auf das geplante Agent-Lease",
        "zh-Hans": "正在等待计划代理租约",
    },
    "Wake planned": {
        "hu": "Ébresztés megtervezve",
        "es": "Despertar planificado",
        "fr": "Réveil planifié",
        "de": "Aufwecken geplant",
        "zh-Hans": "已计划唤醒",
    },
    "Wake preparation started": {
        "hu": "Az ébresztési előkészítés elindult",
        "es": "Comenzó la preparación del despertar",
        "fr": "Préparation du réveil démarrée",
        "de": "Vorbereitung zum Aufwecken gestartet",
        "zh-Hans": "唤醒准备已开始",
    },
    "Wake before run": {
        "hu": "Ébresztés a futás előtt",
        "es": "Despertar antes de la ejecución",
        "fr": "Réveiller avant l’exécution",
        "de": "Vor dem Lauf aufwecken",
        "zh-Hans": "运行前唤醒",
    },
}


CORE = {
    "All Agent and scheduled work finished": {
        "hu": "Minden ügynöki és ütemezett munka befejeződött",
        "es": "Finalizaron todas las tareas de los agentes y las tareas programadas",
        "fr": "Toutes les tâches des agents et les tâches planifiées sont terminées",
        "de": "Alle Agent-Aufgaben und geplanten Aufgaben sind abgeschlossen",
        "zh-Hans": "所有代理任务和计划任务均已完成",
    },
    "All unattended work finished": {
        "hu": "Minden felügyelet nélküli munka befejeződött",
        "es": "Finalizó todo el trabajo sin supervisión",
        "fr": "Tous les travaux sans surveillance sont terminés",
        "de": "Alle unbeaufsichtigten Aufgaben sind abgeschlossen",
        "zh-Hans": "所有无人值守任务均已完成",
    },
}


_FORMAT = re.compile(r"%(?:\d+\$)?(?:0\d)?[@d]|%%")
_FORBIDDEN_DASHES = ("\N{EM DASH}", "\N{EN DASH}")


def _format_specifiers(value: str) -> list[str]:
    """Return normalized printf-style placeholders for comparison."""
    return sorted(re.sub(r"^%\d+\$", "%", match) for match in _FORMAT.findall(value))


def validate() -> None:
    """Validate language coverage, placeholders, content, and prose style."""
    failures = []
    required = set(LANGUAGES)
    for catalog_name, catalog in (("APP", APP), ("CORE", CORE)):
        for key, translations in catalog.items():
            actual = set(translations)
            if actual != required:
                failures.append(
                    f"{catalog_name} {key!r}: languages {sorted(actual)!r}, expected {sorted(required)!r}"
                )
            if any(dash in key for dash in _FORBIDDEN_DASHES):
                failures.append(f"{catalog_name} {key!r}: forbidden dash in source key")
            expected_formats = _format_specifiers(key)
            for language, translation in translations.items():
                if not translation.strip():
                    failures.append(f"{catalog_name} {key!r} {language}: empty translation")
                if _format_specifiers(translation) != expected_formats:
                    failures.append(
                        f"{catalog_name} {key!r} {language}: format specifiers differ"
                    )
                if any(dash in translation for dash in _FORBIDDEN_DASHES):
                    failures.append(
                        f"{catalog_name} {key!r} {language}: forbidden dash in translation"
                    )
    if failures:
        raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    validate()
    print(f"v1.17 main strings: OK (APP {len(APP)}, CORE {len(CORE)})")
