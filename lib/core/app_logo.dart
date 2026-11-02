import 'package:flutter/material.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset('assets/logo.png', width: size, height: size, filterQuality: FilterQuality.medium);
}
