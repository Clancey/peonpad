#ifndef PEONPAD_TABLETOP_SELECTION_POLICY_H
#define PEONPAD_TABLETOP_SELECTION_POLICY_H

struct TabletopSelectionPolicy {
    static constexpr bool CanInspect(bool accessible) noexcept
    {
        return accessible;
    }

    static constexpr bool CanAdd(
        bool targetAccessible,
        bool targetControllable,
        bool targetBuilding,
        bool selectionEmpty,
        bool selectionAllControllable,
        bool selectionHasBuilding) noexcept
    {
        return targetAccessible
            && (selectionEmpty
                || (targetControllable
                    && selectionAllControllable
                    && !targetBuilding
                    && !selectionHasBuilding));
    }

    static constexpr bool CanDispatch(
        bool selectionNonempty,
        bool selectionAllControllable) noexcept
    {
        return selectionNonempty && selectionAllControllable;
    }
};

#endif
