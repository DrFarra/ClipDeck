import SwiftUI
import UIKit

/// Imagen que rellena el hueco que le dan, recortando lo que sobra, sin que su
/// tamaño cuente al maquetar.
///
/// Con `.scaledToFill()` a secas, una imagen en un marco de altura fija pide el
/// ancho que tendría a esa altura: una captura horizontal, más del doble que la
/// columna del historial, que se ensanchaba y se salía de la pantalla. Aquí la
/// imagen va de superposición sobre un hueco vacío, que es lo único que mide.
struct FillImage: View {
    let image: UIImage

    var body: some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
    }
}
