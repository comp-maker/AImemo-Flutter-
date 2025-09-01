import 'package:flutter/material.dart';
import 'data/app_db.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

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
      background: vscodeBg,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MemoQuiz',
      themeMode: ThemeMode.dark,
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

  static const int kNumQuestions = 10; // 항상 10문제 출제
  static const double kOverlayToolbarHeight = 48.0; // 오버레이 툴바 높이(아이콘/패딩 기준)

  @override
  void initState() {
    super.initState();
    _refreshList();
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
    });
    _refreshList();
  }

  Future<void> _save() async {
    if (current == null) return;
    await db.updateTitle(
      current!.id,
      titleCtl.text
          .trim()
          .isEmpty ? '제목 없음' : titleCtl.text.trim(),
    );
    await db.updateContent(current!.id, contentCtl.text);
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
    });
    _refreshList();
  }

  Future<void> _generateQuiz() async {
    if (current == null || contentCtl.text
        .trim()
        .isEmpty) return;

    setState(() => loading = true);
    try {
      final uri = Uri.parse('http://localhost:8787/quiz');
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'content': contentCtl.text,
          'num': kNumQuestions, // ← 항상 10문제
          'type': 'mcq',
        }),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          quiz = data['questions'] ?? [];
          userAnswers = List<int?>.filled(quiz.length, null);
        });
        // DB에 퀴즈 저장
        final quizId = await db.addQuiz(current!.id, jsonEncode(quiz));
        setState(() => currentQuizId = quizId);
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

    int score = 0;
    for (int i = 0; i < quiz.length; i++) {
      if (userAnswers[i] == quiz[i]['answerIndex']) {
        score++;
      }
    }

    await db.addAttempt(currentQuizId!, jsonEncode(userAnswers), score);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('점수: ${score * 10}점 / ${kNumQuestions *
          10}점 만점 (${score}/${kNumQuestions})')),
    );
    // 저장 후 통계를 갱신하고 싶으면 리스트 리프레시
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
      builder: (_) =>
          StatsDialog(
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
              color: selected ? const Color(0xFF007ACC) : const Color(
                  0xFF3C3C3C),
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
          Text(
              label, style: const TextStyle(fontSize: 12, color: Colors.white)),
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
                        padding: EdgeInsets.only(top:12, left: 4, bottom: 6),
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

              // 우측: 에디터 + 퀴즈 (툴바 높이만큼 아래로 내리기)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: kOverlayToolbarHeight + 8),
                  // ★겹침 방지
                  child: current == null
                      ? const Center(
                    child: Text('왼쪽에서 메모를 선택하거나 상단 + 로 새 메모를 만드세요'),
                  )
                      : Padding(
                    padding: const EdgeInsets.all(14.0),
                    child: Column(
                      children: [
                        TextField(
                          controller: titleCtl,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                          decoration:
                          const InputDecoration(hintText: '제목'),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: TextField(
                            controller: contentCtl,
                            maxLines: null,
                            expands: true,
                            keyboardType: TextInputType.multiline,
                            textAlign: TextAlign.start,
                            textAlignVertical: TextAlignVertical.top,
                            // 좌상단 시작
                            decoration: const InputDecoration(
                              hintText: '여기에 메모를 작성하세요…',
                            ),
                          ),
                        ),

                        if (quiz.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: panelBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: const Color(0xFF3C3C3C)),
                            ),
                            child: const Text(
                              '퀴즈 풀기 (10문제)',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 320,
                            child: ListView(
                              children:
                              quiz
                                  .asMap()
                                  .entries
                                  .map<Widget>((entry) {
                                final i = entry.key;
                                final q = entry.value;
                                final choices =
                                    (q['choices'] as List?) ?? [];
                                return Card(
                                  margin:
                                  const EdgeInsets.only(bottom: 10),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Column(
                                      crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                      children: [
                                        Text('${i + 1}. ${q['q']}'),
                                        const SizedBox(height: 8),
                                        ...choices
                                            .asMap()
                                            .entries
                                            .map<Widget>((e) {
                                          return RadioListTile<int>(
                                            value: e.key,
                                            groupValue: userAnswers[i],
                                            onChanged: (val) {
                                              setState(() =>
                                              userAnswers[i] = val);
                                            },
                                            title: Text(
                                                e.value.toString()),
                                            dense: true,
                                          );
                                        }).toList(),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton(
                              onPressed: _submitAnswers,
                              child: const Text('제출하기'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
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
                  onPressed:
                  (loading || current == null) ? null : _generateQuiz,
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
  /// 통계/기록 다이얼로그 (VS Code 다크 톤으로 조정)
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
