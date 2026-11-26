// A seal and a pixel from the component's files, and codes from its data
#import "stamp/helpers.typ": framed

#let seal(size: 1cm) = image("stamp/seal.svg", width: size)
#let codes = json("stamp/data/codes.json")
#let stamp(body) = framed[#seal() #body]
#let pixel(width) = image("/components/stamp/pixel.png", width: width)
