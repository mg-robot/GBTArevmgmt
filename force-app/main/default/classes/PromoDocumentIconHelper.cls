/**
 * Shared icon helper for the Promotions Home tile LWCs. Returns the public ImageServer URL for a
 * Salesforce Document so each tile can render a GBTA-branded image in its lightning-card header.
 *
 * The Document records ARE NOT source-controlled metadata — they're created post-deploy by an
 * admin in the GBTA Logos folder (see docs/promo-code/creation-wizard.md §8). If a Document is
 * missing in a given org, getDocumentImageUrl returns null and the calling LWC falls back to its
 * SLDS icon, so the tile still renders meaningfully.
 *
 * URL shape: /servlet/servlet.ImageServer?id=<docId>&oid=<orgId>. Requires the Document's
 * "Externally Available Image" flag to be true — Salesforce won't serve it otherwise.
 */
public with sharing class PromoDocumentIconHelper {

    /**
     * @param documentName the Document.Name to look up (e.g., 'promo_svg', 'quick_find_promo').
     * @return ImageServer URL for the Document, or null if blank input / Document not found.
     */
    @AuraEnabled(cacheable=true)
    public static String getDocumentImageUrl(String documentName) {
        if (String.isBlank(documentName)) return null;
        for (Document d : [SELECT Id FROM Document WHERE Name = :documentName LIMIT 1]) {
            return '/servlet/servlet.ImageServer?id=' + d.Id +
                   '&oid=' + UserInfo.getOrganizationId();
        }
        return null;
    }
}
