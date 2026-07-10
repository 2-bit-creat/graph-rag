import 'package:flutter/material.dart';

/// Global route observer so data-backed screens can silently refresh when a
/// route pushed on top of them is popped (back navigation). This keeps content
/// fresh ??e.g. returning to the timeline after confirming a graph ??without
/// forcing the user to pull-to-refresh or switch tabs.
///
/// Screens opt in by mixing in [RouteAware], subscribing in
/// `didChangeDependencies` and reloading in `didPopNext`.
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
