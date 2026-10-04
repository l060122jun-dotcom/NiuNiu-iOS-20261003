"""Source/geometry contracts only; run device taps for actual UIKit hit testing."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
BROWSE = (ROOT / 'App/BrowseViews.swift').read_text(encoding='utf-8')


class HitRegionContracts(unittest.TestCase):
    def test_decorative_poster_does_not_receive_touches(self):
        poster = BROWSE.split('private struct PosterView:', 1)[1].split('private struct VideoTile:', 1)[0]
        self.assertIn('.allowsHitTesting(false)', poster)
        self.assertIn('.accessibilityHidden(true)', poster)

    def test_tile_label_owns_bounded_target_and_exact_id(self):
        tile = BROWSE.split('private struct VideoTile:', 1)[1].split('private struct VideoGrid:', 1)[0]
        self.assertIn('DetailView(videoID: video.id)', tile)
        self.assertIn('.frame(maxWidth: .infinity, alignment: .leading)', tile)
        self.assertIn('.contentShape(Rectangle())', tile)
        self.assertNotIn('.onTapGesture', tile)

    def test_button_target_is_defined_before_press_transform(self):
        style = BROWSE.split('private struct BrowsePressStyle:', 1)[1].split('private struct BrowseViewportKey:', 1)[0]
        self.assertLess(style.index('.contentShape(Rectangle())'), style.index('.scaleEffect('))

    def test_search_focus_gesture_excludes_actions(self):
        search = BROWSE.split('struct SearchView:', 1)[1].split('private var searchHeader:', 1)[1].split('var body:', 1)[0]
        focus = search.index('.simultaneousGesture(TapGesture().onEnded { focused = true })')
        self.assertLess(focus, search.index('if !text.isEmpty'))
        self.assertIn('.contentShape(Rectangle())', search[:focus])
        self.assertNotIn('.highPriorityGesture', search)
        self.assertIn('Button(action: closeSearch)', search)
        self.assertIn('Button { submit(text) } label:', search)

    def test_grid_layout_rectangles_never_overlap(self):
        # Model of equal-width HStack columns, not a SwiftUI renderer test.
        for width in (320, 375, 393, 430, 768):
            for columns in (2, 3):
                spacing, inset = 10, 16
                cell = (width - 2 * inset - (columns - 1) * spacing) / columns
                rects = [(inset + i * (cell + spacing), inset + i * (cell + spacing) + cell) for i in range(columns)]
                for i, (left, right) in enumerate(rects):
                    center = (left + right) / 2
                    self.assertEqual([j for j, (a, b) in enumerate(rects) if a <= center < b], [i])
                    if i + 1 < columns:
                        gap = (right + rects[i + 1][0]) / 2
                        self.assertFalse(any(a <= gap < b for a, b in rects))

    def test_glass_and_tab_decorations_do_not_block_controls(self):
        glass = (ROOT / 'App/GlassAppearance.swift').read_text(encoding='utf-8')
        tabs = (ROOT / 'App/GlassTabContainer.swift').read_text(encoding='utf-8')
        self.assertIn('.allowsHitTesting(false)', glass)
        self.assertIn('child.isUserInteractionEnabled = false', tabs)
        self.assertIn('control.addTarget(self, action: #selector(selectTab(_:)), for: .touchUpInside)', tabs)
        self.assertIn('.stroke((dark ? Color.white : Color.black).opacity(0.12), lineWidth: 0.75).allowsHitTesting(false)', BROWSE)

    def test_account_row_boundaries(self):
        account = (ROOT / 'App/AccountViews.swift').read_text(encoding='utf-8')
        self.assertIn('.clipShape(Circle()).contentShape(Circle())', account)
        self.assertIn('.frame(width: 52, height: 70).clipped().cornerRadius(6).contentShape(Rectangle())', account)
        password = account.split('private struct AccountPasswordField:', 1)[1].split('private struct AccountAvatar:', 1)[0]
        self.assertIn('.frame(width: 44, height: 44).contentShape(Rectangle())', password)

    def test_social_compose_row_owns_spacer_area(self):
        social = (ROOT / 'App/SocialViews.swift').read_text(encoding='utf-8')
        row = social.split('Text("也来说一句吧…")', 1)[1].split('}.background(.thinMaterial)', 1)[0]
        self.assertIn('.padding().contentShape(Rectangle())', row)

    def test_player_edge_return_has_no_transparent_blocking_overlay(self):
        detail = (ROOT / 'App/DetailView.swift').read_text(encoding='utf-8')
        self.assertNotIn('edgeBackArea', detail)
        self.assertIn('.simultaneousGesture(edgeBackGesture(fullscreenHost: true))', detail)
        self.assertIn('.simultaneousGesture(edgeBackGesture(fullscreenHost: false))', detail)
        self.assertIn('fullScreen == fullscreenHost', detail)

    def test_player_native_controls_have_explicit_targets(self):
        controls = (ROOT / 'App/AndroidPlayerControls.swift').read_text(encoding='utf-8')
        self.assertIn('Menu { more() }', controls)
        icon = controls.split('private func icon(', 1)[1].split('private func cancelScrubbing', 1)[0]
        self.assertIn('.frame(width: 44, height: 44).contentShape(Rectangle())', icon)
        self.assertIn('pan.delegate = self', controls)
        self.assertIn('gestureRecognizer is UIPanGestureRecognizer', controls)

    def test_multi_button_download_rows_use_independent_style(self):
        detail = (ROOT / 'App/DetailView.swift').read_text(encoding='utf-8')
        self.assertIn('}.buttonStyle(.borderless).disabled(downloading)', detail)
        self.assertIn('}.buttonStyle(.borderless)', detail)


if __name__ == '__main__':
    unittest.main(verbosity=2)
