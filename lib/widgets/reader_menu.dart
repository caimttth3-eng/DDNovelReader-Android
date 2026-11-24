import 'package:flutter/material.dart';

/// A section boundary shared by reading, speech and voice menus.
class ReaderMenuSection extends StatelessWidget {
  final String title;
  final String sectionKey;
  final bool divided;
  final Widget? trailing;
  const ReaderMenuSection({super.key, required this.title, required this.sectionKey, this.divided = false, this.trailing});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (divided) Padding(padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Divider(key: ValueKey('reader-menu-divider-$sectionKey'), height: 1)),
    Padding(padding: EdgeInsets.only(top: divided ? 12 : 8, bottom: 8),
      child: Row(children: [Expanded(child: Text(title, key: ValueKey('reader-menu-section-$sectionKey'),
        style: Theme.of(context).textTheme.titleSmall)), if (trailing != null) trailing!])),
  ]);
}
