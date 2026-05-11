/**
 * Slim Order trigger — delegates all logic to handler classes. Currently only
 * `PromoCodeOrderActivationHandler` is wired (Pending -> Confirmed PCI flips
 * on Status transition to Activated). See docs/promo-code/checkout-apply-flow.md §8.
 */
trigger OrderTrigger on Order(after update) {
  if (Trigger.isAfter && Trigger.isUpdate) {
    new PromoCodeOrderActivationHandler()
      .afterUpdate(Trigger.new, Trigger.oldMap);
  }
}
