import 'package:flutter/material.dart';

import 'theme.dart';

class WorkspaceHeading extends StatelessWidget {
  const WorkspaceHeading(this.title, {super.key, required this.subtitle});
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        liveRegion: true,
        child: Text(title, style: Theme.of(context).textTheme.headlineMedium),
      ),
      const SizedBox(height: 8),
      Text(subtitle, style: const TextStyle(color: mutedInk)),
    ],
  );
}

class WorkspaceSurface extends StatelessWidget {
  const WorkspaceSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

class WorkspaceNotice extends StatelessWidget {
  const WorkspaceNotice({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.error = false,
  });
  final IconData icon;
  final String title;
  final String message;
  final bool error;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: error,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surfaceMuted,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: error ? errorInk : ink),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: error ? errorInk : ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(message, style: const TextStyle(color: mutedInk)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
