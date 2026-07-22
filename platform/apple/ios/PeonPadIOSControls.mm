#include "PeonPadIOSControls.h"
#include "PeonPadIOSControlState.h"

#include <SDL.h>
#include <SDL_syswm.h>
#include <UIKit/UIKit.h>

constexpr CGFloat DockHeight = 54.0;
constexpr CGFloat DockMargin = 6.0;

static PeonPadIOSControlState ControlState;

@interface PeonPadIOSControlDock : UIView
{
	SDL_Window *_window;
	UIButton *_commandButton;
	UIButton *_addButton;
	NSMutableSet<NSNumber *> *_heldKeys;
}

- (instancetype)initWithWindow:(SDL_Window *)window;
- (void)setCommandArmed:(BOOL)armed;

@end

static void PushKeyEvent(SDL_Window *window, SDL_Keycode key, bool pressed)
{
	SDL_Event event;
	SDL_zero(event);
	event.type = pressed ? SDL_KEYDOWN : SDL_KEYUP;
	event.key.timestamp = SDL_GetTicks();
	event.key.windowID = window ? SDL_GetWindowID(window) : 0;
	event.key.state = pressed ? SDL_PRESSED : SDL_RELEASED;
	event.key.repeat = 0;
	event.key.keysym.scancode = SDL_GetScancodeFromKey(key);
	event.key.keysym.sym = key;
	event.key.keysym.mod = KMOD_NONE;
	if (SDL_PushEvent(&event) < 0) {
		SDL_LogError(SDL_LOG_CATEGORY_INPUT,
		             "Could not queue Vision control key event: %s",
		             SDL_GetError());
	}
}

static UIButton *MakeButton(NSString *title, NSString *symbol,
                            NSString *accessibilityLabel)
{
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	button.translatesAutoresizingMaskIntoConstraints = NO;
	button.backgroundColor = [UIColor secondarySystemBackgroundColor];
	button.layer.cornerRadius = 8.0;
	button.clipsToBounds = YES;
	button.accessibilityLabel = accessibilityLabel;
	button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
	[button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
	if (title) {
		[button setTitle:title forState:UIControlStateNormal];
	}
	if (symbol) {
		[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
		button.tintColor = [UIColor labelColor];
	}
	return button;
}

static PeonPadIOSControlDock *ControlDock = nil;
static UIView *ControlDockRoot = nil;

@implementation PeonPadIOSControlDock

- (instancetype)initWithWindow:(SDL_Window *)window
{
	self = [super initWithFrame:CGRectZero];
	if (!self) {
		return nil;
	}

	_window = window;
	_heldKeys = [[NSMutableSet alloc] init];
	self.translatesAutoresizingMaskIntoConstraints = NO;
	self.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.92];
	self.layer.cornerRadius = 12.0;
	self.clipsToBounds = YES;
	self.accessibilityLabel = @"PeonPad controls";

	UIButton *left = MakeButton(nil, @"arrow.left", @"Pan left");
	UIButton *up = MakeButton(nil, @"arrow.up", @"Pan up");
	UIButton *down = MakeButton(nil, @"arrow.down", @"Pan down");
	UIButton *right = MakeButton(nil, @"arrow.right", @"Pan right");
	for (UIButton *button in @[ left, up, down, right ]) {
		[button addTarget:self
		           action:@selector(keyDown:)
		 forControlEvents:UIControlEventTouchDown];
		[button addTarget:self
		           action:@selector(keyUp:)
		 forControlEvents:(UIControlEventTouchUpInside
		                   | UIControlEventTouchUpOutside
		                   | UIControlEventTouchCancel)];
	}
	left.tag = SDLK_LEFT;
	up.tag = SDLK_UP;
	down.tag = SDLK_DOWN;
	right.tag = SDLK_RIGHT;

	_addButton = MakeButton(@"Add", nil, @"Toggle additive selection");
	[_addButton addTarget:self
	               action:@selector(toggleAdditive:)
	     forControlEvents:UIControlEventTouchUpInside];

	_commandButton = MakeButton(@"Cmd", nil, @"Arm next context command");
	[_commandButton addTarget:self
	                   action:@selector(toggleCommand:)
	         forControlEvents:UIControlEventTouchUpInside];

	UIButton *back = MakeButton(@"Back", nil, @"Back or cancel");
	back.tag = SDLK_ESCAPE;
	[back addTarget:self
	         action:@selector(keyTap:)
	   forControlEvents:UIControlEventTouchUpInside];

	UIButton *menu = MakeButton(@"Menu", nil, @"Open game menu");
	menu.tag = SDLK_F10;
	[menu addTarget:self
	         action:@selector(keyTap:)
	   forControlEvents:UIControlEventTouchUpInside];

	UIStackView *stack = [[UIStackView alloc]
		initWithArrangedSubviews:@[ left, up, down, right,
		                           _addButton, _commandButton, back, menu ]];
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	stack.axis = UILayoutConstraintAxisHorizontal;
	stack.alignment = UIStackViewAlignmentFill;
	stack.distribution = UIStackViewDistributionFillEqually;
	stack.spacing = 4.0;
	[self addSubview:stack];

	[NSLayoutConstraint activateConstraints:@[
		[stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:DockMargin],
		[stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-DockMargin],
		[stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:DockMargin],
		[stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-DockMargin],
	]];
#if !__has_feature(objc_arc)
	[stack release];
#endif

	[[NSNotificationCenter defaultCenter]
		addObserver:self
		   selector:@selector(releaseHeldKeys)
		       name:UIApplicationWillResignActiveNotification
		     object:nil];
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
#if !__has_feature(objc_arc)
	[_heldKeys release];
	[super dealloc];
#endif
}

- (void)keyDown:(UIButton *)sender
{
	NSNumber *key = @(sender.tag);
	if ([_heldKeys containsObject:key]) {
		return;
	}
	[_heldKeys addObject:key];
	PushKeyEvent(_window, static_cast<SDL_Keycode>(sender.tag), true);
}

- (void)keyUp:(UIButton *)sender
{
	NSNumber *key = @(sender.tag);
	if (![_heldKeys containsObject:key]) {
		return;
	}
	[_heldKeys removeObject:key];
	PushKeyEvent(_window, static_cast<SDL_Keycode>(sender.tag), false);
}

- (void)keyTap:(UIButton *)sender
{
	const SDL_Keycode key = static_cast<SDL_Keycode>(sender.tag);
	PushKeyEvent(_window, key, true);
	PushKeyEvent(_window, key, false);
}

- (void)toggleAdditive:(UIButton *)sender
{
	ControlState.ToggleAdditive();
	sender.selected = ControlState.IsAdditiveEnabled();
	sender.backgroundColor = ControlState.IsAdditiveEnabled()
		? [[UIColor systemBlueColor] colorWithAlphaComponent:0.72]
		: [UIColor secondarySystemBackgroundColor];
}

- (void)toggleCommand:(UIButton *)sender
{
	ControlState.ToggleContext();
	[self setCommandArmed:ControlState.IsContextArmed()];
}

- (void)setCommandArmed:(BOOL)armed
{
	_commandButton.selected = armed;
	_commandButton.backgroundColor = armed
		? [[UIColor systemOrangeColor] colorWithAlphaComponent:0.78]
		: [UIColor secondarySystemBackgroundColor];
}

- (void)releaseHeldKeys
{
	for (NSNumber *key in [_heldKeys allObjects]) {
		PushKeyEvent(_window, static_cast<SDL_Keycode>(key.integerValue), false);
	}
	[_heldKeys removeAllObjects];
}

@end

void PeonPadIOSInstallControlDock(SDL_Window *window)
{
	if (!window) {
		return;
	}

	SDL_SysWMinfo windowInfo;
	SDL_VERSION(&windowInfo.version);
	if (!SDL_GetWindowWMInfo(window, &windowInfo) || !windowInfo.info.uikit.window) {
		return;
	}

	UIView *rootView = windowInfo.info.uikit.window.rootViewController.view;
	if (!rootView) {
		return;
	}
	if (ControlDock && ControlDockRoot == rootView) {
		[rootView bringSubviewToFront:ControlDock];
		return;
	}

	[ControlDock removeFromSuperview];
#if !__has_feature(objc_arc)
	[ControlDock release];
#endif
	ControlDock = [[PeonPadIOSControlDock alloc] initWithWindow:window];
	ControlDockRoot = rootView;
	[rootView addSubview:ControlDock];

	UILayoutGuide *safeArea = rootView.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[ControlDock.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor
		                                         constant:DockMargin],
		[ControlDock.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor
		                                          constant:-DockMargin],
		[ControlDock.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],
		[ControlDock.heightAnchor constraintEqualToConstant:DockHeight],
	]];
	[rootView bringSubviewToFront:ControlDock];
}

int PeonPadIOSControlDockInsetPoints()
{
	return ControlDock ? static_cast<int>(DockHeight + DockMargin) : 0;
}

unsigned PeonPadIOSMapPointerButton(unsigned button, bool pressed)
{
	const bool wasArmed = ControlState.IsContextArmed();
	const unsigned mappedButton = ControlState.MapPointerButton(button, pressed);
	if (wasArmed && !ControlState.IsContextArmed()) {
		[ControlDock setCommandArmed:NO];
	}
	return mappedButton;
}

bool PeonPadIOSUseAdditiveModifier(bool pressed)
{
	return (ControlState.ApplyPointerModifiers(0, pressed)
	        & InputModifierAdditiveSelection) != 0;
}

void PeonPadIOSResetTouchControls()
{
	ControlState.ResetGesture();
	[ControlDock setCommandArmed:NO];
}
