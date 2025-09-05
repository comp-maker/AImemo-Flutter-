import 'package:flutter/material.dart';
import 'data/app_db.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_quill/flutter_quill.dart' as quill hide Text;
import 'package:flutter_localizations/flutter_localizations.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MemoQuizApp());
}

class MemoQuizApp extends StatelessWidget {
  const MemoQuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    // VS Code 다크 톤
    const vscodeBg = Color(0xFF1E1E1E);
    const panelBg = Color(0xFF252526);
    const cardBg = Color(0xFF2D2D2D);
    const blue = Color(0xFF007ACC);

    final colorScheme = ColorScheme.fromSeed(
      seedColor: blue,
      brightness: Brightness.dark,
      // NOTE: ColorScheme.fromSeed 에 background 인자는 더 이상 받지 않는 버전이 있습니다.
      // 필요 시 scaffoldBackgroundColor 로 대체합니다.
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MemoQuiz',
      themeMode: ThemeMode.dark,
      localizationsDelegates: quill.FlutterQuillLocalizations.localizationsDelegates,
      supportedLocales: quill.FlutterQuillLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: vscodeBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: vscodeBg,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(fontSize: 0), // 상단 제목 숨김
        ),
        cardColor: cardBg,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(borderSide: BorderSide.none),
          filled: true,
          fillColor: panelBg,
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
      home: const HomePage(),
    );
  }
}

/// 메모별 통계 값
class MemoStats {
  final int totalAttempts; // 총 시도 횟수
  final int bestScore;     // 최고 정답 수 (0~10)
  final double avgScore;   // 평균 정답 수

  const MemoStats({
    required this.totalAttempts,
    required this.bestScore,
    required this.avgScore,
  });

  int get bestPercent => bestScore * 10; // 10문제 기준 0~100점
  int get avgPercent => (avgScore * 10).round();
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final db = AppDb();

  List<Memo> memos = [];
  Memo? current;

  final titleCtl = TextEditingController();
  final contentCtl = TextEditingController();

  List<dynamic> quiz = [];
  List<int?> userAnswers = [];
  int? currentQuizId;
  bool loading = false;

  // 상태 변수들 아래에 추가
  bool _examMode = false;                 // ← 시험 모드 ON/OFF
  final ScrollController _examScroll = ScrollController();
  quill.QuillController? _quill;
  final _quillFocus = FocusNode();

  static const int kNumQuestions = 10; // 항상 10문제 출제
  static const double kOverlayToolbarHeight = 48.0; // 오버레이 툴바 높이(아이콘/패딩 기준)

  @override
  void initState() {
    super.initState();
    _refreshList();
  }

  @override
  void dispose() {
    titleCtl.dispose();
    contentCtl.dispose();
    _examScroll.dispose();
    _quillFocus.dispose();
    _quill?.dispose();
    // Drift DB는 앱 종료 때 자동 정리되는 편이지만, 명시하고 싶다면:
    // db.close();
    super.dispose();
  }

  // DB 문자열 → 문서, 문서 → 저장 문자열 헬퍼
  quill.Document _docFromDb(String raw) {
    // Delta JSON이면 파싱, 아니면 일반 텍스트로 문서 생성
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return quill.Document.fromJson(decoded);
      }
    } catch (_) {
      // ignore
    }
    return quill.Document()..insert(0, raw);
  }

  String _docToDb(quill.Document doc) {
    // Delta JSON 문자열로 저장
    final delta = doc.toDelta();
    return jsonEncode(delta.toJson());
  }

  // AI에 보낼 순수 텍스트
  String _plainForAi() => _quill?.document.toPlainText() ?? '';

  // 에디터 위젯 묶음
  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.all(14.0),
      child: Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: titleCtl,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(hintText: '제목'),
          ),
          const SizedBox(height: 8),

          // 툴바: 가로 스크롤 + 고정 높이
          SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: quill.QuillSimpleToolbar(
                controller: _quill!,
                config: const quill.QuillSimpleToolbarConfig(
                  // 필요한 버튼만 남김
                  showBoldButton: true,
                  showItalicButton: true,
                  showUnderLineButton: true,
                  showStrikeThrough: true,
                  showHeaderStyle: true,
                  showUndo: true,
                  showRedo: true,

                  // 나머지 버튼 끄기
                  showLink: false,
                  showListNumbers: false,
                  showListBullets: false,
                  showListCheck: false,
                  showInlineCode: false,
                  showCodeBlock: false,
                  showQuote: false,
                  showColorButton: false,
                  showIndent: false,
                  showAlignmentButtons: false,
                  showDirection: false,
                  showClearFormat: false,
                  showSearchButton: false,
                  showClipboardCopy: false,
                  showClipboardCut: false,
                  showClipboardPaste: false,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // 본문 에디터: Expanded + expands:true
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF252526),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF3C3C3C)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: quill.QuillEditor.basic(
                controller: _quill!,
                focusNode: _quillFocus,
                config: const quill.QuillEditorConfig(
                  expands: true,
                  placeholder: '여기에 메모를 작성하세요…',
                  padding: EdgeInsets.only(top: 10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshList() async {
    final list = await db.listMemos();
    setState(() => memos = list);
  }

  Future<void> _newMemo() async {
    final id = await db.addMemo('새 메모', '');
    final m = await db.getMemo(id);
    setState(() {
      current = m;
      titleCtl.text = current?.title ?? '';
      contentCtl.text = current?.content ?? '';
      quiz = [];
      userAnswers = [];
      currentQuizId = null;
      _examMode = false; // ← 추가: 새 메모 시 시험 모드 해제
      _quill = quill.QuillController(
        document: quill.Document()..insert(0, ''),
        selection: const TextSelection.collapsed(offset: 0),
      );
    });
    _refreshList();
  }

  Future<void> _save() async {
    if (current == null) return;
    await db.updateTitle(
      current!.id,
      titleCtl.text.trim().isEmpty ? '제목 없음' : titleCtl.text.trim(),
    );
    // ✅ quill 문서를 Delta JSON 문자열로 저장
    final contentToSave = _docToDb(_quill!.document);
    await db.updateContent(current!.id, contentToSave);
    final m = await db.getMemo(current!.id);
    setState(() => current = m);
    _refreshList();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('저장 완료')));
  }

  Future<void> _delete() async {
    if (current == null) return;
    await db.deleteMemo(current!.id);
    setState(() {
      current = null;
      titleCtl.clear();
      contentCtl.clear();
      quiz = [];
      userAnswers = [];
      currentQuizId = null;
      _examMode = false; // ← 추가: 삭제 시 시험 모드 해제
    });
    _refreshList();
  }

  Future<void> _generateQuiz() async {
    // NOTE: 기존에는 contentCtl.text 를 검사해서 실제로는 항상 비어있는 것으로 간주되는 문제가 있었습니다.
    // 에디터 내용(_quill) 기준으로 검사하도록 수정합니다.
    if (current == null || _plainForAi().trim().isEmpty) return;

    setState(() => loading = true);
    try {
      final uri = Uri.parse('http://localhost:8787/quiz');
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'content': _plainForAi(),   // ← _quill에서 뽑은 순수 텍스트
          'num': kNumQuestions, // ← 항상 10문제
          'type': 'mcq',
        }),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final qs = (data['questions'] as List?) ?? [];
        if (qs.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('생성된 문제가 없습니다. 내용을 더 자세히 써보세요.')),
          );
          setState(() => _examMode = false);
          return;
        }
        setState(() {
          quiz = qs;
          userAnswers = List<int?>.filled(quiz.length, null);
        });
        // DB에 퀴즈 저장
        final quizId = await db.addQuiz(current!.id, jsonEncode(quiz));
        setState(() {
          currentQuizId = quizId;
          _examMode = true; // ← 시험 모드 진입
        });

        // 문제 생성 후 자동 스크롤 맨 위
        await Future.delayed(const Duration(milliseconds: 50));
        _examScroll.jumpTo(0.0);
      } else {
        throw Exception('서버 오류: ${res.statusCode}');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('문제 생성 실패: $e')));
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _submitAnswers() async {
    if (quiz.isEmpty || currentQuizId == null) return;

    // 답변하지 않은 문항이 있는지 확인
    if (userAnswers.any((e) => e == null)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('답변하지 않은 문항이 있습니다. 모든 문항에 답을 선택해주세요.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    int score = 0;
    for (int i = 0; i < quiz.length; i++) {
      if (userAnswers[i] == quiz[i]['answerIndex']) {
        score++;
      }
    }

    await db.addAttempt(currentQuizId!, jsonEncode(userAnswers), score);

    if (!mounted) return;
    final total = quiz.length; // ← 실제 출제 문항 수
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('점수: ${score * 10}점 / ${total * 10}점 만점 (${score}/${total})')),
    );

    // ⬇️ 시험 모드 종료 + 문제 패널 닫기
    setState(() {
      _examMode = false;
      // 필요하면 문제는 남겨두고 싶다면 아래 두 줄은 주석 처리
      // quiz = [];
      // userAnswers = [];
    });

    // 통계 갱신 등
    _refreshList();
  }

  /// 메모별 통계 계산(모든 퀴즈의 모든 시도를 합산)
  Future<MemoStats> _loadMemoStats(int memoId) async {
    final quizzes = await db.listQuizzesForMemo(memoId);
    int totalAttempts = 0;
    int bestScore = 0;
    int sumScore = 0;

    for (final q in quizzes) {
      final attempts = await db.listAttemptsForQuiz(q.id);
      totalAttempts += attempts.length;
      for (final a in attempts) {
        if (a.score > bestScore) bestScore = a.score;
        sumScore += a.score;
      }
    }
    final avg = totalAttempts == 0 ? 0.0 : (sumScore / totalAttempts);
    return MemoStats(
        totalAttempts: totalAttempts, bestScore: bestScore, avgScore: avg);
  }

  Future<void> _openHistoryForCurrent() async {
    if (current == null) return;
    final memoId = current!.id;

    // 통계 + 최근 시도 목록 수집
    final quizzes = await db.listQuizzesForMemo(memoId);
    final stats = await _loadMemoStats(memoId);

    // 최근 시도: (quiz별 attempts를 합쳐 날짜 내림차순)
    final List<Attempt> allAttempts = [];
    for (final q in quizzes) {
      final attempts = await db.listAttemptsForQuiz(q.id);
      allAttempts.addAll(attempts);
    }
    allAttempts.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => StatsDialog(
        memoTitle: current!.title.isEmpty ? '제목 없음' : current!.title,
        stats: stats,
        attempts: allAttempts,
        totalQuestions: kNumQuestions,
      ),
    );
  }

  // 메모 카드 UI (VS Code 스타일 + 통계 배지)
  Widget _memoCard(Memo m, bool selected) {
    return FutureBuilder<MemoStats>(
      future: _loadMemoStats(m.id),
      builder: (context, snap) {
        final stats = snap.data ??
            const MemoStats(totalAttempts: 0, bestScore: 0, avgScore: 0);

        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2A2D2E) : const Color(0xFF2D2D2D),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? const Color(0xFF007ACC) : const Color(0xFF3C3C3C),
              width: selected ? 1.5 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: const Color(0xFF007ACC).withOpacity(0.25),
                      blurRadius: 8,
                      spreadRadius: 0.5,
                    ),
                  ]
                : null,
          ),
          child: Stack(
            children: [
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        m.title.isEmpty ? '제목 없음' : m.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6, right: 90),
                  // 배지와 겹치지 않도록 여백
                  child: Text(
                    m.updatedAt.toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xFFBBBBBB), fontSize: 12),
                  ),
                ),
                onTap: () async {
                  final full = await db.getMemo(m.id);
                  setState(() {
                    current = full;
                    titleCtl.text = current?.title ?? '';
                    contentCtl.text = current?.content ?? '';
                    quiz = [];
                    userAnswers = [];
                    currentQuizId = null;
                    _examMode = false; // ← 추가: 메모 바꿀 때 시험 모드 해제
                    _quill = quill.QuillController(
                      document: _docFromDb(current?.content ?? ''),
                      selection: const TextSelection.collapsed(offset: 0),
                    );
                  });
                },
              ),

              // 오른쪽 위: 총 시도 횟수 배지
              Positioned(
                right: 10,
                top: 8,
                child: _badge(
                  icon: Icons.task_alt,
                  label: '${stats.totalAttempts}회',
                  color: const Color(0xFF3A3D41),
                ),
              ),

              // 오른쪽 아래: 최고 점수 배지
              Positioned(
                right: 10,
                bottom: 8,
                child: _badge(
                  icon: Icons.emoji_events,
                  label: '${stats.bestScore * 10}점',
                  color: const Color(0xFF2E7D32), // 약간의 그린
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _badge(
      {required IconData icon, required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const panelBg = Color(0xFF252526);
    const blue = Color(0xFF007ACC);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // (A) 본 레이아웃: 왼쪽 사이드바 + 구분선 + 오른쪽 에디터
          Row(
            children: [
              // 좌측 사이드바 (위 여백 0으로! 상단에 딱 붙게)
              SizedBox(
                width: 320,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), // ← top 0
                  decoration: const BoxDecoration(color: panelBg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 12, left: 4, bottom: 6),
                        child: Text(
                          '메모 목록',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Expanded(
                        child: ListView.builder(
                          itemCount: memos.length,
                          itemBuilder: (context, i) {
                            final m = memos[i];
                            final selected = current?.id == m.id;
                            return _memoCard(m, selected);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 구분선
              Container(width: 1, color: const Color(0xFF3C3C3C)),

              // 우측: 에디터 또는 시험 모드
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: kOverlayToolbarHeight + 8),
                  child: _examMode
                      // ===== 시험 모드 화면 =====
                      ? Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF252526), // panelBg
                            border: Border.all(color: const Color(0xFF3C3C3C)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Stack(
                            children: [
                              // 문제 리스트
                              Positioned.fill(
                                child: ListView.builder(
                                  controller: _examScroll,
                                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 80),
                                  itemCount: quiz.length,
                                  itemBuilder: (context, idx) {
                                    final q = quiz[idx];
                                    final choices = (q['choices'] as List?) ?? [];
                                    return Card(
                                      margin: const EdgeInsets.only(bottom: 10),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12.0),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text('${idx + 1}. ${q['q']}'),
                                            const SizedBox(height: 8),
                                            ...choices.asMap().entries.map((e) {
                                              return RadioListTile<int>(
                                                value: e.key,
                                                groupValue: userAnswers[idx],
                                                onChanged: (val) {
                                                  setState(() => userAnswers[idx] = val);
                                                },
                                                title: Text(e.value.toString()),
                                                dense: true,
                                              );
                                            }),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),

                              // 상단 고정 바(시험 모드 표시 + 닫기)
                              Positioned(
                                left: 0,
                                right: 0,
                                top: 0,
                                child: Container(
                                  height: 44,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF2D2D2D),
                                    border: Border(
                                      bottom: BorderSide(color: Color(0xFF3C3C3C)),
                                    ),
                                    borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.assignment, size: 18, color: Colors.white70),
                                      const SizedBox(width: 8),
                                      const Text('시험 모드', style: TextStyle(fontWeight: FontWeight.bold)),
                                      const Spacer(),
                                      // (선택) 취소 버튼: 제출 없이 나가기
                                      TextButton(
                                        onPressed: () {
                                          final answered = userAnswers.where((e) => e != null).length;
                                          showDialog(
                                            context: context,
                                            builder: (context) => AlertDialog(
                                              backgroundColor: const Color(0xFF252526),
                                              title: const Text('시험 모드 종료'),
                                              content: Text('제출하지 않고 나가시겠습니까?\n현재 ${answered}/${quiz.length}문항에 답했습니다.\n답변은 저장되지 않습니다.'),
                                              actions: [
                                                TextButton(
                                                  onPressed: () => Navigator.of(context).pop(),
                                                  child: const Text('취소'),
                                                ),
                                                TextButton(
                                                  onPressed: () {
                                                    Navigator.of(context).pop();
                                                    setState(() {
                                                      _examMode = false;
                                                      // 필요 시 문제 유지/초기화 선택
                                                      // quiz = []; userAnswers = [];
                                                    });
                                                  },
                                                  child: const Text('나가기'),
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                        child: const Text('나가기'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              // 하단 제출 버튼 고정
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  height: 64,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF2D2D2D),
                                    border: Border(
                                      top: BorderSide(color: Color(0xFF3C3C3C)),
                                    ),
                                    borderRadius: BorderRadius.vertical(bottom: Radius.circular(10)),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Row(
                                    children: [
                                      const Text('모든 문항에 답을 선택한 후 제출하세요'),
                                      const Spacer(),
                                      FilledButton(
                                        onPressed: userAnswers.any((e) => e == null) ? null : _submitAnswers,
                                        child: const Text('제출'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                                          // ===== 기존 에디터 화면 =====
                    : (current == null
                        ? const Center(
                            child: Text('왼쪽에서 메모를 선택하거나 상단 + 로 새 메모를 만드세요'),
                          )
                        : _buildEditor()),
                ),
              ),
            ],
          ),

          // (B) 상단 오버레이 툴바(버튼들)
          Positioned(
            top: 6,
            right: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                    onPressed: _newMemo,
                    tooltip: '새 메모',
                    icon: const Icon(Icons.add)),
                IconButton(
                    onPressed: _save,
                    tooltip: '저장',
                    icon: const Icon(Icons.save)),
                IconButton(
                    onPressed: _delete,
                    tooltip: '삭제',
                    icon: const Icon(Icons.delete)),
                IconButton(
                    onPressed: _openHistoryForCurrent,
                    tooltip: '기록',
                    icon: const Icon(Icons.bar_chart)),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: (loading || current == null) ? null : _generateQuiz,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('문제 생성'),
                  style: FilledButton.styleFrom(
                    backgroundColor: blue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFF3A3D41),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

//  ────────────────────────────────────────────────────────────────────────────
//  통계/기록 다이얼로그 (VS Code 다크 톤으로 조정)
//  ────────────────────────────────────────────────────────────────────────────
class StatsDialog extends StatelessWidget {
  final String memoTitle;
  final MemoStats stats;
  final List<Attempt> attempts;
  final int totalQuestions;

  const StatsDialog({
    super.key,
    required this.memoTitle,
    required this.stats,
    required this.attempts,
    required this.totalQuestions,
  });

  @override
  Widget build(BuildContext context) {
    const panelBg = Color(0xFF252526);
    const cardBg = Color(0xFF2D2D2D);
    const green = Color(0xFF2E7D32);
    const blue = Color(0xFF007ACC);

    String fmt(DateTime dt) {
      // 간단한 표시
      return '${dt.year}년 ${dt.month}월 ${dt.day}일 '
          '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    }

    Widget metricCard(IconData icon, String title, String value, {Color? color}) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF3C3C3C)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: (color ?? blue).withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color ?? blue, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12)),
                  const SizedBox(height: 6),
                  Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      backgroundColor: panelBg,
      contentPadding: const EdgeInsets.all(16),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 16, 0),
      title: Row(
        children: [
          const Icon(Icons.bar_chart, color: blue),
          const SizedBox(width: 8),
          Expanded(
            child: Text('문제 풀이 기록 - $memoTitle',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 상단 메트릭 3개
            Row(
              children: [
                Expanded(child: metricCard(Icons.center_focus_strong, '총 시도 횟수', '${stats.totalAttempts}회')),
                const SizedBox(width: 10),
                Expanded(child: metricCard(Icons.emoji_events, '최고 점수', '${stats.bestPercent}점', color: green)),
                const SizedBox(width: 10),
                Expanded(child: metricCard(Icons.trending_up, '평균 점수', '${stats.avgPercent}점')),
              ],
            ),
            const SizedBox(height: 16),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('최근 시도 기록',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            // 최근 시도 리스트
            SizedBox(
              height: 260,
              child: ListView.builder(
                itemCount: attempts.length,
                itemBuilder: (context, i) {
                  final a = attempts[i];
                  final isLatest = i == 0;
                  final correct = a.score;
                  final scoreBadge = '${correct * 10}점';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF3C3C3C)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.event, color: Color(0xFFBBBBBB)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${fmt(a.createdAt)}   ${correct}/${totalQuestions} 정답',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 10),
                        _smallBadge(scoreBadge, background: const Color(0xFF2E7D32)),
                        const SizedBox(width: 6),
                        if (isLatest)
                          _smallBadge('최신', background: blue),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          child: const Text('닫기'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _smallBadge(String text, {required Color background}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
    );
  }
}

// ---- 퀴즈 리뷰(문항/선택지만 열람) ----
class QuizReviewPage extends StatelessWidget {
  final String quizJson;
  final List<Attempt> attempts;
  const QuizReviewPage({
    super.key,
    required this.quizJson,
    required this.attempts,
  });

  @override
  Widget build(BuildContext context) {
    const cardBg = Color(0xFF2D2D2D);
    final quizList = (jsonDecode(quizJson) as List);

    return Scaffold(
      appBar: AppBar(title: const SizedBox.shrink()),
      body: Padding(
        padding: const EdgeInsets.all(14.0),
        child: ListView(
          children: [
            ...quizList.asMap().entries.map<Widget>((entry) {
              final i = entry.key;
              final q = entry.value;
              final choices = (q['choices'] as List?) ?? [];
              return Card(
                color: cardBg,
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${i + 1}. ${q['q']}'),
                      const SizedBox(height: 6),
                      ...choices.asMap().entries.map<Widget>((e) {
                        return Text('(${e.key + 1}) ${e.value}');
                      }).toList(),
                    ],
                  ),
                ),
              );
            }).toList(),
            const Divider(),
            const Text('시도 기록'),
            const SizedBox(height: 6),
            ...attempts.map<Widget>((a) => Card(
                  color: cardBg,
                  child: ListTile(
                    title: Text('시도 ${a.id} - 점수 ${a.score * 10}점'),
                    subtitle: Text(a.createdAt.toString()),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
