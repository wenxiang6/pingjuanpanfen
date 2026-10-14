import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'ui/judge_main_page.dart';

/// 侧边竖长窗口默认尺寸
const Size kWindowSize = Size(380, 900);
const Size kWindowMinSize = Size(340, 620);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面端 SQLite（sqflite_common_ffi 需要先初始化 ffi 实现）
  sqfliteFfiInit();

  await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: kWindowSize,
    minimumSize: kWindowMinSize,
    center: false,
    skipTaskbar: false,
    title: '阅卷辅助小助手',
    alwaysOnTop: true,
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const JudgeAssistantApp());
}

class JudgeAssistantApp extends StatelessWidget {
  const JudgeAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '阅卷辅助小助手',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const JudgeMainPage(),
    );
  }
}
