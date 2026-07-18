# -*- coding: utf-8 -*-
"""East Asian strings introduced by the AI power orchestration work.

This overlay intentionally mirrors the APP and CORE key sets in
v117_main_strings.py. Run this file directly to validate coverage, printf-style
placeholders, and the repository's prose style rule.
"""

import re

try:
    from .v117_main_strings import APP as MAIN_APP, CORE as MAIN_CORE
except ImportError:
    from v117_main_strings import APP as MAIN_APP, CORE as MAIN_CORE


LANGUAGES = ("ja", "ko", "zh-Hant")


APP = {
    "%d active Agent lease(s)": {
        "ja": "有効なエージェントのスリープ防止リース：%d 件",
        "ko": "활성 에이전트 깨우기 리스 %d개",
        "zh-Hant": "%d 個作用中的代理喚醒租約",
    },
    "%d active local automation(s)": {
        "ja": "有効なローカル自動化：%d 件",
        "ko": "활성 로컬 자동화 %d개",
        "zh-Hant": "%d 個作用中的本機自動化",
    },
    "%d automation file(s) could not be used": {
        "ja": "%d 件の自動化ファイルを使用できませんでした",
        "ko": "자동화 파일 %d개를 사용할 수 없음",
        "zh-Hant": "%d 個自動化檔案無法使用",
    },
    "%d%%": {
        "ja": "%d%%",
        "ko": "%d%%",
        "zh-Hant": "%d%%",
    },
    "+%d more Agent lease(s)": {
        "ja": "ほかにエージェントのスリープ防止リースが %d 件",
        "ko": "에이전트 깨우기 리스 %d개 더 있음",
        "zh-Hant": "另有 %d 個代理喚醒租約",
    },
    "20 minutes": {
        "ja": "20 分",
        "ko": "20분",
        "zh-Hant": "20 分鐘",
    },
    "After all unattended work": {
        "ja": "すべての無人作業後",
        "ko": "모든 무인 작업 후",
        "zh-Hant": "所有無人值守工作完成後",
    },
    "Agent and unattended log": {
        "ja": "エージェントと無人作業のログ",
        "ko": "에이전트 및 무인 작업 로그",
        "zh-Hant": "代理與無人值守記錄",
    },
    "Agent lease: %@": {
        "ja": "エージェントのスリープ防止リース：%@",
        "ko": "에이전트 깨우기 리스: %@",
        "zh-Hant": "代理喚醒租約：%@",
    },
    "Agent wake lease expired": {
        "ja": "エージェントのスリープ防止リースが期限切れになりました",
        "ko": "에이전트 깨우기 리스가 만료됨",
        "zh-Hant": "代理喚醒租約已到期",
    },
    "Agent work owns keep-awake until every lease and scheduled handoff finishes.": {
        "ja": "すべてのリースと予定された引き継ぎが完了するまで、エージェント作業がスリープ防止を維持します。",
        "ko": "모든 리스와 예약된 인계가 끝날 때까지 에이전트 작업이 깨어 있게 유지를 제어합니다.",
        "zh-Hant": "代理工作會維持保持喚醒，直到所有租約與排定的交接都完成。",
    },
    "An Agent stopped renewing its lease. Keepresso released that task's wake request safely.": {
        "ja": "エージェントがリースの更新を停止しました。Keepresso はそのタスクのスリープ防止要求を安全に解除しました。",
        "ko": "에이전트가 리스 갱신을 중단했습니다. Keepresso가 해당 작업의 깨우기 요청을 안전하게 해제했습니다.",
        "zh-Hant": "代理已停止續租。Keepresso 已安全釋放該工作的喚醒要求。",
    },
    "Automation prompt text is discarded during parsing and is never retained, displayed, or logged. Configure the Keepresso Skill or MCP server so each Agent acquires, renews, and releases its own lease.": {
        "ja": "自動化のプロンプト本文は解析時に破棄され、保存、表示、記録されることはありません。各エージェントが自身のリースを取得、更新、解放するように、Keepresso Skill または MCP サーバーを設定してください。",
        "ko": "자동화 프롬프트 텍스트는 분석 중 폐기되며 저장, 표시 또는 기록되지 않습니다. 각 에이전트가 자신의 리스를 획득, 갱신 및 해제하도록 Keepresso Skill 또는 MCP 서버를 구성하십시오.",
        "zh-Hant": "自動化提示文字會在解析時捨棄，絕不保留、顯示或記錄。請設定 Keepresso Skill 或 MCP 伺服器，讓每個代理自行取得、續租並釋放租約。",
    },
    "Automation discovery completed": {
        "ja": "自動化の検出が完了しました",
        "ko": "자동화 검색 완료",
        "zh-Hant": "自動化探索已完成",
    },
    "Automation discovery failed": {
        "ja": "自動化を検出できませんでした",
        "ko": "자동화 검색 실패",
        "zh-Hant": "自動化探索失敗",
    },
    "Closed-lid protection needs the administrator helper.": {
        "ja": "蓋を閉じた状態の保護には管理者ヘルパーが必要です。",
        "ko": "덮개를 닫은 상태의 보호에는 관리자 도우미가 필요합니다.",
        "zh-Hant": "闔蓋保護需要管理員輔助程式。",
    },
    "Codex automation did not claim a wake lease": {
        "ja": "Codex 自動化がスリープ防止リースを取得しませんでした",
        "ko": "Codex 자동화가 깨우기 리스를 획득하지 않음",
        "zh-Hant": "Codex 自動化未取得喚醒租約",
    },
    "Codex automation idle": {
        "ja": "Codex 自動化は待機中です",
        "ko": "Codex 자동화 유휴 상태",
        "zh-Hant": "Codex 自動化閒置中",
    },
    "Codex automation needs the administrator helper": {
        "ja": "Codex 自動化には管理者ヘルパーが必要です",
        "ko": "Codex 자동화에 관리자 도우미가 필요함",
        "zh-Hant": "Codex 自動化需要管理員輔助程式",
    },
    "Codex automation preparation": {
        "ja": "Codex 自動化を準備中",
        "ko": "Codex 자동화 준비",
        "zh-Hant": "正在準備 Codex 自動化",
    },
    "Codex automation readiness failed": {
        "ja": "Codex 自動化の準備確認に失敗しました",
        "ko": "Codex 자동화 준비 상태 확인 실패",
        "zh-Hant": "Codex 自動化就緒檢查失敗",
    },
    "Codex automation wake": {
        "ja": "Codex 自動化用のスリープ解除",
        "ko": "Codex 자동화 깨우기",
        "zh-Hant": "Codex 自動化喚醒",
    },
    "Codex automation wake is saved but inactive until the administrator helper is ready.": {
        "ja": "Codex 自動化用のスリープ解除は保存されていますが、管理者ヘルパーの準備が整うまで有効になりません。",
        "ko": "Codex 자동화 깨우기가 저장되었지만 관리자 도우미가 준비될 때까지 비활성 상태입니다.",
        "zh-Hant": "Codex 自動化喚醒已儲存，但要等管理員輔助程式就緒後才會生效。",
    },
    "Codex automation was not started": {
        "ja": "Codex 自動化は開始されませんでした",
        "ko": "Codex 자동화가 시작되지 않음",
        "zh-Hant": "Codex 自動化未啟動",
    },
    "Follow local Codex automations": {
        "ja": "ローカルの Codex 自動化に連動",
        "ko": "로컬 Codex 자동화 따르기",
        "zh-Hant": "跟隨本機 Codex 自動化",
    },
    "Held by %d Agent lease(s)": {
        "ja": "%d 件のエージェントリースがスリープを防止中",
        "ko": "에이전트 리스 %d개가 깨어 있게 유지 중",
        "zh-Hant": "%d 個代理租約正在保持喚醒",
    },
    "Install and approve the helper before relying on unattended wake or closed-lid work.": {
        "ja": "無人でのスリープ解除や蓋を閉じたままの作業を利用する前に、ヘルパーをインストールして承認してください。",
        "ko": "무인 깨우기 또는 덮개를 닫은 작업을 사용하기 전에 도우미를 설치하고 승인하십시오.",
        "zh-Hant": "依賴無人喚醒或闔蓋工作前，請先安裝並核准輔助程式。",
    },
    "Keepresso extracts only scheduling metadata from enabled local Codex automations. It wakes the Mac before the nearest run, waits for power, battery, network, and the Codex app, then holds the Mac until the Agent acquires an explicit lease or the handoff times out.": {
        "ja": "Keepresso は、有効なローカル Codex 自動化からスケジュールのメタデータだけを抽出します。次の実行前に Mac のスリープを解除し、電源、バッテリー、ネットワーク、Codex App の準備を待ってから、エージェントが明示的なリースを取得するか引き継ぎが時間切れになるまで Mac のスリープを防止します。",
        "ko": "Keepresso는 활성화된 로컬 Codex 자동화에서 일정 메타데이터만 추출합니다. 가장 가까운 실행 전에 Mac을 깨우고 전원, 배터리, 네트워크 및 Codex 앱이 준비되기를 기다린 다음, 에이전트가 명시적 리스를 획득하거나 인계 시간이 만료될 때까지 Mac을 깨어 있게 유지합니다.",
        "zh-Hant": "Keepresso 只會從已啟用的本機 Codex 自動化中擷取排程中繼資料。它會在最近一次執行前喚醒 Mac，等待電源、電池、網路及 Codex App 就緒，然後讓 Mac 保持喚醒，直到代理取得明確租約或交接逾時。",
    },
    "Keepresso released the expired handoff requests. Any Agent leases still active remain protected.": {
        "ja": "Keepresso は期限切れの引き継ぎ要求を解除しました。まだ有効なエージェントリースは引き続き保護されます。",
        "ko": "Keepresso가 만료된 인계 요청을 해제했습니다. 아직 활성 상태인 에이전트 리스는 계속 보호됩니다.",
        "zh-Hant": "Keepresso 已釋放到期的交接要求。仍在作用中的代理租約會繼續受到保護。",
    },
    "Lease acquired": {
        "ja": "リースを取得しました",
        "ko": "리스 획득됨",
        "zh-Hant": "已取得租約",
    },
    "Lease changed by another process": {
        "ja": "別のプロセスがリースを変更しました",
        "ko": "다른 프로세스가 리스를 변경함",
        "zh-Hant": "租約已由其他程序變更",
    },
    "Lease heartbeat received": {
        "ja": "リースのハートビートを受信しました",
        "ko": "리스 하트비트 수신됨",
        "zh-Hant": "已收到租約活動訊號",
    },
    "Lease released": {
        "ja": "リースを解放しました",
        "ko": "리스 해제됨",
        "zh-Hant": "已釋放租約",
    },
    "Lease renewed": {
        "ja": "リースを更新しました",
        "ko": "리스 갱신됨",
        "zh-Hant": "已續租",
    },
    "Lease restored after restart": {
        "ja": "再起動後にリースを復元しました",
        "ko": "재시동 후 리스 복원됨",
        "zh-Hant": "重新啟動後已還原租約",
    },
    "Lease timed out": {
        "ja": "リースが時間切れになりました",
        "ko": "리스 시간 초과",
        "zh-Hant": "租約已逾時",
    },
    "Lock screen before unattended work": {
        "ja": "無人作業の前に画面をロック",
        "ko": "무인 작업 전에 화면 잠그기",
        "zh-Hant": "無人值守工作前鎖定螢幕",
    },
    "MCP server": {
        "ja": "MCP サーバー",
        "ko": "MCP 서버",
        "zh-Hant": "MCP 伺服器",
    },
    "Minimum battery": {
        "ja": "最低バッテリー残量",
        "ko": "최소 배터리 잔량",
        "zh-Hant": "最低電池電量",
    },
    "Next run: %@": {
        "ja": "次の実行：%@",
        "ko": "다음 실행: %@",
        "zh-Hant": "下次執行：%@",
    },
    "Next wake: %@": {
        "ja": "次のスリープ解除：%@",
        "ko": "다음 깨우기: %@",
        "zh-Hant": "下次喚醒：%@",
    },
    "No Agent or unattended activity yet.": {
        "ja": "エージェントまたは無人作業の履歴はまだありません。",
        "ko": "아직 에이전트 또는 무인 작업 활동이 없습니다.",
        "zh-Hant": "尚無代理或無人值守活動。",
    },
    "No enabled local Codex automation found": {
        "ja": "有効なローカル Codex 自動化が見つかりません",
        "ko": "활성화된 로컬 Codex 자동화를 찾을 수 없음",
        "zh-Hant": "找不到已啟用的本機 Codex 自動化",
    },
    "Opening Codex": {
        "ja": "Codex を開いています",
        "ko": "Codex 여는 중",
        "zh-Hant": "正在開啟 Codex",
    },
    "Power, network, or the Codex application did not become ready in time.": {
        "ja": "電源、ネットワーク、または Codex アプリケーションの準備が時間内に整いませんでした。",
        "ko": "전원, 네트워크 또는 Codex 응용 프로그램이 제시간에 준비되지 않았습니다.",
        "zh-Hant": "電源、網路或 Codex 應用程式未能及時就緒。",
    },
    "Preparation window is open now": {
        "ja": "現在は準備時間内です",
        "ko": "현재 준비 시간 범위에 있음",
        "zh-Hant": "目前已進入準備時段",
    },
    "Readiness timeout": {
        "ja": "準備確認のタイムアウト",
        "ko": "준비 상태 시간 제한",
        "zh-Hant": "就緒檢查逾時",
    },
    "Readiness checks passed": {
        "ja": "準備確認に合格しました",
        "ko": "준비 상태 확인 통과",
        "zh-Hant": "就緒檢查已通過",
    },
    "Readiness retry scheduled": {
        "ja": "準備確認の再試行を予定しました",
        "ko": "준비 상태 재확인 예약됨",
        "zh-Hant": "已排定重試就緒檢查",
    },
    "Readiness timed out": {
        "ja": "準備確認が時間切れになりました",
        "ko": "준비 상태 확인 시간 초과",
        "zh-Hant": "就緒檢查已逾時",
    },
    "Require external power": {
        "ja": "外部電源を必須にする",
        "ko": "외부 전원 필요",
        "zh-Hant": "需要外接電源",
    },
    "Require minimum battery": {
        "ja": "最低バッテリー残量を必須にする",
        "ko": "최소 배터리 잔량 필요",
        "zh-Hant": "需要最低電池電量",
    },
    "Require network": {
        "ja": "ネットワークを必須にする",
        "ko": "네트워크 필요",
        "zh-Hant": "需要網路",
    },
    "Reveal Keepresso Agent Skill": {
        "ja": "Keepresso Agent Skill を表示",
        "ko": "Keepresso Agent Skill 보기",
        "zh-Hant": "顯示 Keepresso Agent Skill",
    },
    "Scheduled Agent lease active": {
        "ja": "予定されたエージェントリースが有効です",
        "ko": "예약된 에이전트 리스 활성 상태",
        "zh-Hant": "排定的代理租約正在作用中",
    },
    "Scheduled and Agent-driven jobs use a separate secure policy. By default Keepresso locks the login session, turns off the display while preserving the system assertion, and sleeps the Mac after the final job finishes.": {
        "ja": "予定されたジョブとエージェント駆動のジョブには、専用の安全なポリシーが適用されます。デフォルトでは、Keepresso はログインセッションをロックし、システムのスリープ防止を維持したままディスプレイをオフにして、最後のジョブが完了した後に Mac をスリープさせます。",
        "ko": "예약된 작업과 에이전트 구동 작업에는 별도의 보안 정책이 적용됩니다. 기본적으로 Keepresso는 로그인 세션을 잠그고 시스템의 절전 방지를 유지하면서 디스플레이를 끈 다음, 마지막 작업이 끝나면 Mac을 잠자기 상태로 전환합니다.",
        "zh-Hant": "排定的工作與代理驅動工作會使用個別的安全策略。Keepresso 預設會鎖定登入工作階段，在保留系統防睡眠判定的同時關閉顯示器，並在最後一項工作完成後讓 Mac 進入睡眠。",
    },
    "Some Codex automations did not claim a wake lease": {
        "ja": "一部の Codex 自動化がスリープ防止リースを取得しませんでした",
        "ko": "일부 Codex 자동화가 깨우기 리스를 획득하지 않음",
        "zh-Hant": "部分 Codex 自動化未取得喚醒租約",
    },
    "Structured events only, with no automation prompts or command arguments. Saved at %@": {
        "ja": "自動化プロンプトやコマンド引数を含まない構造化イベントだけを記録します。保存先：%@",
        "ko": "자동화 프롬프트나 명령 인수 없이 구조화된 이벤트만 기록합니다. 저장 위치: %@",
        "zh-Hant": "只記錄結構化事件，不包含自動化提示或指令引數。儲存位置：%@",
    },
    "System is eligible to sleep": {
        "ja": "システムはスリープ可能です",
        "ko": "시스템을 잠자기 상태로 전환할 수 있음",
        "zh-Hant": "系統現在可以進入睡眠",
    },
    "The Agent lease registry could not be opened.": {
        "ja": "エージェントリースのレジストリを開けませんでした。",
        "ko": "에이전트 리스 레지스트리를 열 수 없습니다.",
        "zh-Hant": "無法開啟代理租約登錄檔。",
    },
    "The Agent lease registry could not be read.": {
        "ja": "エージェントリースのレジストリを読み込めませんでした。",
        "ko": "에이전트 리스 레지스트리를 읽을 수 없습니다.",
        "zh-Hant": "無法讀取代理租約登錄檔。",
    },
    "The handoff window expired, so Keepresso restored normal sleep safely.": {
        "ja": "引き継ぎ時間が終了したため、Keepresso は通常のスリープ設定を安全に復元しました。",
        "ko": "인계 시간이 만료되어 Keepresso가 정상 잠자기를 안전하게 복원했습니다.",
        "zh-Hant": "交接時段已到期，因此 Keepresso 已安全還原正常睡眠。",
    },
    "These defaults do not change interactive keep-awake sessions.": {
        "ja": "これらのデフォルト設定は、対話型のスリープ防止セッションには影響しません。",
        "ko": "이 기본값은 대화형 깨어 있게 유지 세션을 변경하지 않습니다.",
        "zh-Hant": "這些預設值不會變更互動式保持喚醒工作階段。",
    },
    "Turn Off Codex Automation Wake": {
        "ja": "Codex 自動化用のスリープ解除をオフ",
        "ko": "Codex 자동화 깨우기 끄기",
        "zh-Hant": "關閉 Codex 自動化喚醒",
    },
    "Turn display off before unattended work": {
        "ja": "無人作業の前にディスプレイをオフ",
        "ko": "무인 작업 전에 디스플레이 끄기",
        "zh-Hant": "無人值守工作前關閉顯示器",
    },
    "Unattended Agent work": {
        "ja": "エージェントの無人作業",
        "ko": "에이전트 무인 작업",
        "zh-Hant": "無人值守代理工作",
    },
    "Unattended event": {
        "ja": "無人作業イベント",
        "ko": "무인 작업 이벤트",
        "zh-Hant": "無人值守事件",
    },
    "Unattended orchestration cancelled": {
        "ja": "無人オーケストレーションをキャンセルしました",
        "ko": "무인 오케스트레이션 취소됨",
        "zh-Hant": "無人值守編排已取消",
    },
    "Unattended task cancelled": {
        "ja": "無人タスクをキャンセルしました",
        "ko": "무인 작업 취소됨",
        "zh-Hant": "無人值守工作已取消",
    },
    "Unattended task failed": {
        "ja": "無人タスクに失敗しました",
        "ko": "무인 작업 실패",
        "zh-Hant": "無人值守工作失敗",
    },
    "Unattended task started": {
        "ja": "無人タスクを開始しました",
        "ko": "무인 작업 시작됨",
        "zh-Hant": "無人值守工作已啟動",
    },
    "Unattended task succeeded": {
        "ja": "無人タスクが完了しました",
        "ko": "무인 작업 성공",
        "zh-Hant": "無人值守工作成功完成",
    },
    "Unattended task timed out": {
        "ja": "無人タスクが時間切れになりました",
        "ko": "무인 작업 시간 초과",
        "zh-Hant": "無人值守工作已逾時",
    },
    "Unattended work: %@": {
        "ja": "無人作業：%@",
        "ko": "무인 작업: %@",
        "zh-Hant": "無人值守工作：%@",
    },
    "Wait for Agent lease": {
        "ja": "エージェントリースを待機",
        "ko": "에이전트 리스 기다리기",
        "zh-Hant": "等待代理租約",
    },
    "Waiting for power, network, and Codex": {
        "ja": "電源、ネットワーク、Codex を待機中",
        "ko": "전원, 네트워크 및 Codex 기다리는 중",
        "zh-Hant": "正在等待電源、網路及 Codex",
    },
    "Waiting for the scheduled Agent lease": {
        "ja": "予定されたエージェントリースを待機中",
        "ko": "예약된 에이전트 리스 기다리는 중",
        "zh-Hant": "正在等待排定的代理租約",
    },
    "Wake planned": {
        "ja": "スリープ解除を予定しました",
        "ko": "깨우기 계획됨",
        "zh-Hant": "已規劃喚醒",
    },
    "Wake preparation started": {
        "ja": "スリープ解除の準備を開始しました",
        "ko": "깨우기 준비 시작됨",
        "zh-Hant": "喚醒準備已開始",
    },
    "Wake before run": {
        "ja": "実行前にスリープを解除",
        "ko": "실행 전 깨우기",
        "zh-Hant": "執行前喚醒",
    },
}


CORE = {
    "All Agent and scheduled work finished": {
        "ja": "すべてのエージェント作業と予定された作業が完了しました",
        "ko": "모든 에이전트 및 예약 작업 완료",
        "zh-Hant": "所有代理工作與排定工作均已完成",
    },
    "All unattended work finished": {
        "ja": "すべての無人作業が完了しました",
        "ko": "모든 무인 작업 완료",
        "zh-Hant": "所有無人值守工作均已完成",
    },
}


_FORMAT = re.compile(r"%(?:\d+\$)?(?:0\d)?[@d]|%%")
_FORBIDDEN_DASHES = ("\N{EM DASH}", "\N{EN DASH}")


def _format_specifiers(value: str) -> list[str]:
    """Return normalized printf-style placeholders for comparison."""
    return sorted(re.sub(r"^%\d+\$", "%", match) for match in _FORMAT.findall(value))


def validate() -> None:
    """Validate exact key parity, language coverage, placeholders, and prose style."""
    failures = []
    required_languages = set(LANGUAGES)
    for catalog_name, catalog, main_catalog in (
        ("APP", APP, MAIN_APP),
        ("CORE", CORE, MAIN_CORE),
    ):
        missing = set(main_catalog) - set(catalog)
        extra = set(catalog) - set(main_catalog)
        if missing:
            failures.append(f"{catalog_name}: missing keys {sorted(missing)!r}")
        if extra:
            failures.append(f"{catalog_name}: extra keys {sorted(extra)!r}")

        for key, translations in catalog.items():
            actual_languages = set(translations)
            if actual_languages != required_languages:
                failures.append(
                    f"{catalog_name} {key!r}: languages {sorted(actual_languages)!r}, "
                    f"expected {sorted(required_languages)!r}"
                )
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
    print(
        f"v1.17 east strings: OK (APP {len(APP)}, CORE {len(CORE)}, "
        f"languages {len(LANGUAGES)})"
    )
