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
  static const double kExamTopBarHeight = 44.0;      // 시험 모드 상단바 높이
  static const double kExamBottomBarHeight = 64.0;   // 하단 제출바 높이

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

  // 메모 전체 텍스트에서 문장 단위로 자르기
  List<String> _splitSentences(String text) {
    return text
        .split(RegExp(r'(?<=[\.?\!])\s+|\n+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
  }

  // 간단 토크나이저(질문/정답에서 키워드 뽑기)
  List<String> _extractTokens(String text) {
    final raw = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '');
    final parts = raw.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty);
    return parts.where((w) => w.length >= 2).toList();
  }

  // 질문 객체(q, choices, answerIndex)를 바탕으로, 메모 텍스트에서 가장 관련있는 문장 찾기
  Map<String, dynamic> _locateSourceForQuestion(
    Map q,
    String memoPlainText,
  ) {
    final question = (q['q'] ?? '').toString();
    final choices = (q['choices'] as List?) ?? const [];
    final answerIndex = (q['answerIndex'] as int?) ?? -1;
    final correct =
        (answerIndex >= 0 && answerIndex < choices.length) ? choices[answerIndex].toString() : '';

    final tokens = <String>[
      ..._extractTokens(question),
      ..._extractTokens(correct),
      ..._extractTokens((q['explanation'] ?? '').toString()),
    ].toSet().toList();

    final sentences = _splitSentences(memoPlainText);
    if (sentences.isEmpty) {
      return {'snippet': '', 'sentIndex': -1};
    }

    int scoreFor(String s) {
      final low = s.toLowerCase();
      var score = 0;
      for (final t in tokens) {
        if (t.isEmpty) continue;
        if (low.contains(t)) score += t.length;
      }
      return score;
    }

    var bestIdx = 0;
    var bestScore = -1;
    for (var i = 0; i < sentences.length; i++) {
      final sc = scoreFor(sentences[i]);
      if (sc > bestScore) {
        bestScore = sc;
        bestIdx = i;
      }
    }

    if (bestScore <= 0) {
      final s = sentences.first;
      return {'snippet': s.trim(), 'sentIndex': 0};
    }

    final prev = (bestIdx - 1 >= 0) ? sentences[bestIdx - 1] : '';
    final curr = sentences[bestIdx];
    final next = (bestIdx + 1 < sentences.length) ? sentences[bestIdx + 1] : '';
    final snippet = [prev, curr, next].where((x) => x.trim().isNotEmpty).join(' ');
    return {'snippet': snippet.trim(), 'sentIndex': bestIdx};
  }

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

  Future<void> _applyTidyAndSave(String tidy) async {
    if (current == null) return;
    setState(() {
      _quill = quill.QuillController(
        document: quill.Document()..insert(0, tidy.trimRight()),
        selection: const TextSelection.collapsed(offset: 0),
      );
    });
    await _save();
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

        // 출처 스니펫 붙이기
        final memoText = _plainForAi();
        final enriched = qs.map((raw) {
          final qMap = Map<String, dynamic>.from(raw as Map);
          final src = _locateSourceForQuestion(qMap, memoText);
          qMap['sourceSnippet'] = src['snippet'];
          qMap['sourceIndex'] = src['sentIndex'];
          return qMap;
        }).toList();

        setState(() {
          quiz = enriched;
          userAnswers = List<int?>.filled(quiz.length, null);
        });
        // DB에 퀴즈 저장(enriched)
        final quizId = await db.addQuiz(current!.id, jsonEncode(enriched));
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
      if (userAnswers[i] == quiz[i]['answerIndex']) score++;
    }

    // 시도 저장
    await db.addAttempt(
      currentQuizId!,
      jsonEncode(userAnswers), // 사용자가 고른 보기 인덱스 배열
      score,                   // 정답 개수
    );

    if (!mounted) return;

    // 시험 모드 종료 & 리스트 갱신
    setState(() => _examMode = false);
    _refreshList();

    // 결과 화면으로 이동 (Google Forms 스타일)
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => QuizResultPage(
          quiz: List<Map<String, dynamic>>.from(
            quiz.map((e) => Map<String, dynamic>.from(e as Map)),
          ),
          userAnswers: List<int>.from(userAnswers.map((e) => e!)),
          totalCorrect: score,
          memoPlainText: _plainForAi(),
        ),
      ),
    );

    // 결과 화면에서 '다시 풀기'를 누르면 재시작
    if (!mounted) return;
    if (result == 'retake') {
      setState(() {
        _examMode = true;
        userAnswers = List<int?>.filled(quiz.length, null);
      });
      await Future.delayed(const Duration(milliseconds: 50));
      _examScroll.jumpTo(0.0);
    }
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

  Future<void> _openTidyDialog() async {
    if (current == null) return;
    final original = _plainForAi();

    final appliedText = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TidyDialog(originalText: original),
    );
    if (appliedText != null) {
      await _applyTidyAndSave(appliedText);
    }
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
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    14 + kExamTopBarHeight,
                                    14,
                                    16 + kExamBottomBarHeight,
                                  ),
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
                                  height: kExamTopBarHeight,
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
                                  height: kExamBottomBarHeight,
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
                // 👇 메모 정리 버튼 (아이보리)
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: (loading || current == null || _examMode) ? null : _openTidyDialog,
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('메모 정리'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF2EEDC),
                    foregroundColor: const Color(0xFF1E1E1E),
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

// 결과 화면: 사용자가 고른 답/정답/해설 표시 + 다시 풀기/닫기
class QuizResultPage extends StatelessWidget {
  final List<Map<String, dynamic>> quiz;
  final List<int> userAnswers;
  final int totalCorrect;
  final String memoPlainText;

  const QuizResultPage({
    super.key,
    required this.quiz,
    required this.userAnswers,
    required this.totalCorrect,
    required this.memoPlainText,
  });

  @override
  Widget build(BuildContext context) {
    void _showSourceBottomSheet(BuildContext context, String full, String snippet) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) {
          Widget highlighted(String text, String query) {
            final lowText = text.toLowerCase();
            final lowQuery = query.toLowerCase();
            final idx = lowText.indexOf(lowQuery);
            if (idx < 0 || query.trim().isEmpty) {
              return const SelectableText(
                '',
              );
            }
            final before = text.substring(0, idx);
            final mid = text.substring(idx, idx + query.length);
            final after = text.substring(idx + query.length);
            return SelectableText.rich(
              TextSpan(children: [
                const TextSpan(text: '', style: TextStyle(color: Colors.white70)),
                TextSpan(text: before, style: const TextStyle(color: Colors.white70)),
                TextSpan(
                  text: mid,
                  style: const TextStyle(
                    color: Color(0xFFE53935),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextSpan(text: after, style: const TextStyle(color: Colors.white70)),
              ]),
            );
          }

          return DraggableScrollableSheet(
            expand: false,
            minChildSize: 0.4,
            initialChildSize: 0.7,
            builder: (context, controller) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  controller: controller,
                  child: highlighted(full, snippet),
                ),
              );
            },
          );
        },
      );
    }
    const panelBg = Color(0xFF252526);
    const cardBg  = Color(0xFF2D2D2D);
    const green   = Color(0xFF2E7D32);
    const red     = Color(0xFFB00020);
    const blue    = Color(0xFF007ACC);

    final total = quiz.length;

    Widget metric(IconData icon, String title, String value, {Color? color}) {
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('풀이 결과'),
        centerTitle: false,
      ),
      body: Container(
        color: panelBg,
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: metric(Icons.task_alt, '정답 수', '$totalCorrect/$total', color: green)),
                const SizedBox(width: 10),
                Expanded(child: metric(Icons.percent, '점수', '${totalCorrect * 10}점', color: blue)),
              ],
            ),
            const SizedBox(height: 14),

            Expanded(
              child: ListView.builder(
                itemCount: total,
                itemBuilder: (context, i) {
                  final q = quiz[i];
                  final choices = (q['choices'] as List?) ?? const [];
                  final answerIndex = (q['answerIndex'] as int?) ?? -1;
                  final userIdx = userAnswers[i];
                  final correct = userIdx == answerIndex;

                  Color borderColor(bool isCorrect, bool isUserWrongPick) {
                    if (isCorrect) return green.withOpacity(0.7);
                    if (isUserWrongPick) return red.withOpacity(0.7);
                    return const Color(0xFF3C3C3C);
                  }

                  return Card(
                    color: cardBg,
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(correct ? Icons.check_circle : Icons.cancel,
                                  color: correct ? green : red, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text('${i + 1}. ${q['q']}',
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ...choices.asMap().entries.map((e) {
                            final idx = e.key;
                            final text = e.value.toString();
                            final isCorrect = idx == answerIndex;
                            final isUserPick = idx == userIdx;
                            final isUserWrongPick = isUserPick && !isCorrect;

                            return Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: isCorrect
                                    ? green.withOpacity(0.18)
                                    : (isUserWrongPick
                                        ? red.withOpacity(0.18)
                                        : cardBg),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: borderColor(isCorrect, isUserWrongPick),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isCorrect
                                        ? Icons.check
                                        : (isUserWrongPick
                                            ? Icons.close
                                            : Icons.circle_outlined),
                                    size: 16,
                                    color: isCorrect
                                        ? green
                                        : (isUserWrongPick
                                            ? red
                                            : const Color(0xFFBBBBBB)),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(text)),
                                ],
                              ),
                            );
                          }),

                          if ((q['explanation'] ?? '').toString().trim().isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text('해설: ${q['explanation']}',
                                style: const TextStyle(color: Color(0xFFBBBBBB))),
                          ],

                          // 출처(메모) 표시 + 원문 보기
                          () {
                            final source = (q['sourceSnippet'] ?? '').toString().trim();
                            if (source.isEmpty) return const SizedBox.shrink();
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1F1F1F),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFF3C3C3C)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('출처(메모 내용)',
                                          style: TextStyle(fontWeight: FontWeight.w700)),
                                      const SizedBox(height: 6),
                                      Text(
                                        source,
                                        style: const TextStyle(color: Color(0xFFBBBBBB)),
                                      ),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton.icon(
                                          onPressed: () => _showSourceBottomSheet(context, memoPlainText, source),
                                          icon: const Icon(Icons.chrome_reader_mode, size: 16),
                                          label: const Text('원문 보기'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          }(),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            Row(
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('닫기'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop('retake'),
                  child: const Text('다시 풀기'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TidyDialog extends StatefulWidget {
  final String originalText;
  const TidyDialog({super.key, required this.originalText});

  @override
  State<TidyDialog> createState() => _TidyDialogState();
}

class _TidyDialogState extends State<TidyDialog> {
  String? tidyText;
  String? errorMsg;
  bool loading = true;
  bool saving = false;
  // 두 패널용 컨트롤러
  final _leftScroll = ScrollController();
  final _rightScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _runTidy();
  }

  @override
  void dispose() {
    _leftScroll.dispose();
    _rightScroll.dispose();
    super.dispose();
  }

  Future<void> _runTidy() async {
    try {
      final uri = Uri.parse('http://localhost:8787/tidy');
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'content': widget.originalText,
          'style': 'concise vsc-dark bullet/heading friendly',
        }),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final t = (data['tidy'] ?? data['text'] ?? '').toString().trim();
        if (t.isEmpty) throw Exception('서버 결과가 비어 있습니다.');
        setState(() {
          tidyText = t;
          loading = false;
        });
      } else {
        throw Exception('서버 오류: ${res.statusCode}');
      }
    } catch (e) {
      final fallback = widget.originalText
          .replaceAll(RegExp(r'[ \t]+'), ' ')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();

      setState(() {
        errorMsg = '$e';
        tidyText = fallback.isEmpty ? null : fallback;
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const panelBg = Color(0xFF252526);
    const cardBg  = Color(0xFF2D2D2D);

    return AlertDialog(
      backgroundColor: panelBg,
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 16, 0),
      contentPadding: const EdgeInsets.all(12),
      title: Row(
        children: const [
          Icon(Icons.auto_fix_high, color: Color(0xFF007ACC)),
          SizedBox(width: 8),
          Text('메모 정리 미리보기', style: TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: 920,
        height: 540,
        child: Column(
          children: [
            if (errorMsg != null) ...[
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF4E342E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'AI 요청에 실패했습니다. 임시 정리본으로 미리보기를 제공합니다.\n$errorMsg',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _pane(
                      title: '변경 전 (원문)',
                      text: widget.originalText,
                      cardBg: cardBg,
                      controller: _leftScroll,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: loading
                        ? _loadingPane(cardBg)
                        : _pane(
                            title: '변경 후 (정리본)',
                            text: tidyText ?? '',
                            cardBg: cardBg,
                            controller: _rightScroll,
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        TextButton.icon(
          icon: const Icon(Icons.check),
          label: const Text('적용'),
          onPressed: (saving || (tidyText ?? '').trim().isEmpty)
              ? null
              : () async {
                  setState(() => saving = true);
                  // 즉시 저장은 다이얼로그 밖(HomePageState)에서 처리하되, 값만 반환
                  Navigator.of(context).pop(tidyText);
                },
        ),
      ],
    );
  }

  Widget _loadingPane(Color cardBg) {
    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3C3C3C)),
      ),
      child: const Center(
        child: Padding(
          padding: EdgeInsets.all(12.0),
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }

  Widget _pane({
    required String title,
    required String text,
    required Color cardBg,
    required ScrollController controller,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3C3C3C)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Expanded(
            child: Scrollbar(
              controller: controller,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: controller,
                padding: const EdgeInsets.all(8),
                child: SelectableText(
                  (text.isEmpty ? ' ' : text),
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
