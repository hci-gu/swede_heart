import 'package:flutter/cupertino.dart';

class AppTheme {
  static double basePadding = 8.0;

  static const TextStyle headLine1 = TextStyle(
    fontSize: 48,
    fontWeight: FontWeight.w800,
  );
  static const TextStyle headLine2 = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w700,
  );
  static const TextStyle headLine3 = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
  );
  static const TextStyle headLine3Light = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w300,
  );

  static const TextStyle paragraphMedium = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w300,
  );
  static const TextStyle paragraph = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle paragraphSmall = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle labelXLarge = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
  );
  static const TextStyle labelLarge = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
  );
  static const TextStyle labelMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w700,
  );
  static const TextStyle labelSmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
  );
  static const TextStyle labelTiny = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: CupertinoColors.systemGrey,
  );
  static const TextStyle labelXTiny = TextStyle(
    fontSize: 8,
    fontWeight: FontWeight.w500,
    color: CupertinoColors.systemGrey,
  );

  static Widget spacer = SizedBox(width: basePadding, height: basePadding);
  static Widget spacer2x = SizedBox(
    width: basePadding * 2,
    height: basePadding * 2,
  );

  static Widget get separator => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16.0),
    child: Container(height: 1, color: const Color.fromRGBO(0, 0, 0, 0.1)),
  );
}

class AppScaffold extends StatelessWidget {
  final Widget child;
  final String? title;
  final bool withPadding;
  final bool noBackButton;

  const AppScaffold({
    super.key,
    required this.child,
    this.title,
    this.withPadding = true,
    this.noBackButton = false,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: title != null ? Text(title!, style: AppTheme.headLine3) : null,
        leading: noBackButton ? SizedBox(width: 0, height: 0) : null,
      ),
      child: Padding(
        padding: withPadding
            ? EdgeInsetsGeometry.symmetric(
                horizontal: AppTheme.basePadding * 2,
                vertical: AppTheme.basePadding,
              )
            : EdgeInsets.zero,
        child: child,
      ),
    );
  }
}
